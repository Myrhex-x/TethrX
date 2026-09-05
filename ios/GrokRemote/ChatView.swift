import SwiftUI
import UIKit
import PhotosUI

/// Live conversation for one session, styled as a Grok Build console.
struct ChatView: View {
    @StateObject var vm: ChatViewModel
    @StateObject private var dictation = Dictation()
    @State private var draft = ""
    @State private var showDetails = false
    @State private var showGit = false
    @State private var showFiles = false
    @State private var atBottom = true
    @FocusState private var composerFocused: Bool
    /// Whether the composer's chip row is wider than the space it has. Only then is
    /// a fade at its trailing edge telling the truth.
    @State private var chipsContentWidth: CGFloat = 0
    @State private var chipsViewportWidth: CGFloat = 0
    private var chipsScroll: Bool { chipsContentWidth > chipsViewportWidth + 1 }
    /// A fixed 18pt of fade, expressed as the fraction of the row it happens to be.
    private var chipsFadeStart: CGFloat {
        guard chipsViewportWidth > 40 else { return 0.9 }
        return 1 - min(0.4, 18 / chipsViewportWidth)
    }

    // Image attachments waiting in the composer (JPEG data + display thumbnails).
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var attachments: [Data] = []
    @State private var attachmentThumbs: [UIImage] = []
    // Text files picked from Files/iCloud. Grok can read anything on the COMPUTER,
    // so a log or a config that only exists on the phone has to travel in the prompt.
    @State private var files: [TextAttachment] = []
    @State private var importingFile = false
    @State private var importingAudio = false
    /// Transcribing a recording takes a moment; the + button says so meanwhile.
    @State private var transcribing = false
    @State private var showPhotoPicker = false
    @State private var fileError: String?
    /// The exact draft text dictation last wrote. Anything else appearing in the
    /// draft is the person typing, and re-bases the recogniser.
    @State private var dictated = ""
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
                                    .font(Grok.sans(11)).monospacedDigit()
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
        .fileImporter(isPresented: $importingAudio,
                      allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            importAudio(result)
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
            // The same scroller the composer's chip row uses, for the same reason: the
            // four labels are as wide as their translation makes them, and "Dateien
            // Änderungen Session Suchen" beside the plan pill is wider than the strip.
            // A bare row answers that by wrapping the words inside their own capsules.
            ScrollView(.horizontal, showsIndicators: false) {
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
                }
            }
            // Where grok is in its own checklist, without scrolling back to the card.
            // It keeps its width and the chips give way, not the other way round.
            if !vm.plan.isEmpty, vm.busy || !vm.plan.allDone {
                PlanProgressPill(entries: vm.plan)
                    .layoutPriority(1)
            }
            if vm.mode == "plan" {
                Text("Plan").font(Grok.sans(12, .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Grok.accent).clipShape(Capsule())
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, Grok.gutter).padding(.top, 10).padding(.bottom, 4)
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
                // What you type here is a word, not a command, so it is set in the
                // reading face like the rest of the bar.
                .font(Grok.sans(15)).foregroundStyle(Grok.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($findFocused)
                .submitLabel(.search)
                .onSubmit { step(+1, in: matches) }
            if !matches.isEmpty {
                Text(verbatim: "\(min(findCursor + 1, matches.count))/\(matches.count)")
                    .font(Grok.sans(14)).foregroundStyle(Grok.textDim).monospacedDigit()
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
        .padding(.horizontal, Grok.pad)
        .padding(.vertical, 2)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous)
            .stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
        .padding(.horizontal, Grok.gutter).padding(.bottom, 6)
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
            Text(title).lineLimit(1).chip(on: false)
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
                        if vm.items.isEmpty, vm.session.seedContext?.isEmpty != false {
                            // Filling the viewport is what stops the transcript's
                            // bottom anchor from parking a short blank page against
                            // the composer with a screen of void above it.
                            blankSession.frame(minHeight: max(0, outer.size.height - 56))
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
                    .padding(.horizontal, Grok.gutter).padding(.vertical, 18)
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
    /// An empty conversation, with the three things worth asking first.
    ///
    /// The openers used to be the person's own saved prompts, offered as pills above
    /// the composer. A saved prompt is a library entry, not a suggestion: three
    /// arbitrary snippets stacked over the box answered a question nobody had asked,
    /// and pushed the box itself down the screen. These are openers for a coding
    /// agent that has just been pointed at a folder, and they sit on the blank page
    /// where the blank page already was.
    private var blankSession: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            TethrXMark(size: 44, color: .white.opacity(0.12))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)
            ListSectionLabel("Start with").padding(.bottom, 2)
            ForEach(starters.indices, id: \.self) { i in
                let text = String(loc: starters[i])
                Button {
                    Haptics.tap()
                    draft = text
                    dictated = draft
                    composerFocused = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: text)
                            .font(Grok.sans(16))
                            .foregroundStyle(Grok.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Grok.textFaint)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Puts this in the message box"))
            }
            Spacer(minLength: 24)
        }
    }

    /// Deliberately about the work rather than about the app: orient, review, verify.
    private var starters: [String.LocalizationValue] {
        ["What does this project do?",
         "What changed recently?",
         "Run the tests and tell me what fails"]
    }

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
                Text("Waiting for you").font(Grok.sans(15, .semibold))
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
            // The one control in the app that genuinely hovers over moving text, so
            // it is the one that most wants a lens: you can see the conversation
            // through it, which is how you know it is over the conversation.
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Grok.text)
                .frame(width: 44, height: 44)
                .floatingGlass(in: Circle())
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

    /// One card: the message on top, everything you can do to it underneath, the way
    /// Grok's own composer is built. The controls used to live in a separate scrolling
    /// strip above the field, which read as a toolbar bolted on rather than part of
    /// the thing you are writing in.
    private var composer: some View {
        VStack(spacing: 0) {
            queuedRow
            attachmentsRow
            filesRow
            commandPalette
            composerCard
                .padding(.horizontal, Grok.gutter).padding(.top, 10).padding(.bottom, 10)
        }
        .background(
            LinearGradient(colors: [Grok.bg.opacity(0), Grok.bg, Grok.bg],
                           startPoint: .top, endPoint: .bottom)
        )
        // The recogniser reports the whole utterance each time it revises, so
        // mirroring it into the draft unconditionally undid every edit made while the
        // mic was live. The draft is the source of truth: dictation writes into it,
        // and an edit that did not come from dictation re-bases the recogniser.
        .onChange(of: dictation.transcript) { _, v in
            guard dictation.isRecording else { return }
            dictated = v
            if draft != v { draft = v }
        }
        .onChange(of: draft) { _, v in
            guard dictation.isRecording, v != dictated else { return }
            dictated = v
            dictation.rebase(to: v)
        }
    }

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("", text: $draft,
                      prompt: (vm.busy ? Text("Queue a follow-up") : Text("Ask Grok anything"))
                          .foregroundColor(Grok.textFaint),
                      axis: .vertical)
                .font(Grok.body())
                .foregroundStyle(Grok.text)
                .lineLimit(1...6)
                .focused($composerFocused)

            HStack(spacing: 8) {
                // No `scrollClipDisabled` here. It let the chips paint outside the
                // card and straight over the send button: fine in English, where
                // "Reads only" is short, and a mess in French, where the same chip
                // reads "Lectures seules" and the row is wider than the card.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { attachMenu; controlChips }
                        .background(GeometryReader { c in
                            Color.clear.preference(key: ChipsWidthKey.self, value: c.size.width)
                        })
                }
                .background(GeometryReader { v in
                    Color.clear.preference(key: ChipsViewportKey.self, value: v.size.width)
                })
                .onPreferenceChange(ChipsWidthKey.self) { chipsContentWidth = $0 }
                .onPreferenceChange(ChipsViewportKey.self) { chipsViewportWidth = $0 }
                // The fade says "there is more, scroll". Applied unconditionally it
                // said it even when there wasn't, dimming the last chip for no reason.
                .mask(chipsScroll
                      ? AnyView(LinearGradient(stops: [.init(color: .black, location: 0),
                                                       .init(color: .black, location: chipsFadeStart),
                                                       .init(color: .clear, location: 1)],
                                               startPoint: .leading, endPoint: .trailing))
                      : AnyView(Color.black))
                trailingButtons
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        // The composer floats over the conversation rather than sitting in it, which
        // is the one thing that earns real glass. On iOS 26 the messages pass behind
        // a lens; below it, the hand-built version of the same idea. The recording
        // ring goes on last either way — it has to be legible against whatever the
        // material happens to be showing at that moment.
        .floatingGlass(in: RoundedRectangle(cornerRadius: Grok.R.field, style: .continuous),
                       interactive: false)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.field, style: .continuous)
            .stroke(dictation.isRecording ? Color.white.opacity(0.4) : .clear, lineWidth: 1))
    }

    /// The `+`: one affordance for everything that can ride along with a message.
    @ViewBuilder private var attachMenu: some View {
        if !vm.busy {
            // Attachments and nothing else. Saved prompts used to hang off the
            // bottom of this menu, which made a paperclip mean two unrelated things.
            // They live on the home screen and in Settings, where they are a library.
            Menu {
                Button { importingFile = true } label: { Label("Attach a file", systemImage: "doc") }
                Button { showPhotoPicker = true } label: { Label("Attach images", systemImage: "photo") }
                Button { importingAudio = true } label: { Label("Attach audio", systemImage: "waveform") }
            } label: {
                let loaded = !attachments.isEmpty || !files.isEmpty
                Group {
                    if transcribing {
                        ProgressView().controlSize(.small).tint(Grok.textDim)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(loaded ? Color.black : Grok.textDim)
                    }
                }
                .roundControl(on: loaded)
            }
            .accessibilityLabel("Add an attachment")
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItems,
                          maxSelectionCount: 3, matching: .images)
        }
    }

    /// Dictation lives at the end of the row, where Grok puts its mic — and gives way
    /// to send the moment there is something to send.
    @ViewBuilder private var micButton: some View {
        if dictation.supported {
            Button { dictation.toggle(base: draft) } label: {
                ZStack {
                    // While recording, the ring swells with your voice. A mic that
                    // looks identical whether or not it can hear you is half of what
                    // "the mic doesn\u{2019}t work" means.
                    if dictation.isRecording {
                        Circle()
                            .fill(Grok.accent.opacity(0.22))
                            .scaleEffect(1 + 0.35 * dictation.level)
                            .animation(.easeOut(duration: 0.12), value: dictation.level)
                    }
                    Image(systemName: dictation.isRecording ? "waveform" : "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(dictation.isRecording ? .black : Grok.textDim)
                        .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                }
                .roundControl(on: dictation.isRecording)
                // 34pt to the eye, 44pt to the finger.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
            .accessibilityHint(Text("Long-press to change the dictation language"))
            // Recognition language ≠ app language: someone using the app in English
            // may well dictate in French.
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

    // Failures here used to be written to vm.errorMessage and never shown, so a
    // decision that didn't reach the bridge looked like it had worked.
    @ViewBuilder private var errorBanner: some View {
        if let message = vm.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Text("!").font(Grok.sans(15, .bold)).foregroundStyle(Grok.danger)
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
            .padding(.horizontal, Grok.gutter).padding(.vertical, 10)
            .background(Grok.danger.opacity(0.10))
            .overlay(Rectangle().fill(Grok.danger.opacity(0.3)).frame(height: 1), alignment: .top)
        }
    }

    // Send when idle; when a turn is running, queue the draft (＋) or stop (■).
    @ViewBuilder private var trailingButtons: some View {
        if vm.busy {
            HStack(spacing: 8) {
                // No mic while a turn runs. It cost 52pt beside the stop button, which
                // was exactly enough to push the control chips out of the card in
                // Spanish, German and French; and while Grok is working, stop is the
                // button that has to be unmistakable. Dictation is back the moment the
                // turn ends.
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
            if sendable {
                CircleIconButton(system: "arrow.up", filled: true, a11y: "Send") { submit(draft) }
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                micButton
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
                                .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairlineStrong, lineWidth: 1))
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
                .padding(.horizontal, Grok.gutter).padding(.top, 10).padding(.bottom, 2)
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
                        .font(Grok.sans(14, .medium))
                        .foregroundStyle(Grok.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Grok.hairlineStrong, lineWidth: 1))
                    }
                }
                .padding(.horizontal, Grok.gutter).padding(.top, 10)
            }
        }
    }

    /// Read the picked files as text. Grok reads files on the computer itself, so
    /// anything that only exists on the phone has to be carried in the prompt, which
    /// is why this is capped and why binaries are refused rather than mangled.
    /// An attached recording becomes words before it becomes a message. Nothing in
    /// the prompt pipeline can carry audio, and transcribing on the phone is also the
    /// only version of this that keeps the recording off the network.
    private func importAudio(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { fileError = error.localizedDescription }
            return
        }
        transcribing = true
        Task {
            defer { transcribing = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try await AudioTranscription.text(from: url, localeId: dictation.localeId)
                let name = url.lastPathComponent
                let block = String(loc: "Transcript of \(name):") + "\n\n" + text
                draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? block : draft + "\n\n" + block
                dictated = draft
                Haptics.success()
                composerFocused = true
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

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
                fileError = String(loc: "That file couldn't be read.")
                continue
            }
            guard data.count <= TextAttachment.limit else {
                fileError = String(loc: "That file is too large to send. The limit is 64 KB.")
                continue
            }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !text.contains("\u{0}") else {
                fileError = String(loc: "That looks like a binary file. Only text can be sent.")
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
                        .font(Grok.sans(14, .medium))
                        .foregroundStyle(Grok.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Grok.hairlineStrong, lineWidth: 1))
                    }
                }
                .padding(.horizontal, Grok.gutter)
            }
            .padding(.top, 10)
        }
    }

    // Plan mode, reasoning effort and the approval floor, as chips inside the
    // composer card — the same place Grok keeps DeepSearch and Think.
    @ViewBuilder private var controlChips: some View {
        Group {
                Button { Task { await vm.setConfig(planMode: !vm.planMode) } } label: {
                    Label("Plan", systemImage: "list.bullet.clipboard").chip(on: vm.planMode)
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(Array(efforts.enumerated()), id: \.offset) { _, pair in
                        Button(pair.0) { Task { await vm.setConfig(effort: pair.1) } }
                    }
                } label: {
                    Label(effortLabel, systemImage: "gauge.with.needle").chip(on: effectiveEffort != "high")
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
            .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairlineStrong, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
            .padding(.horizontal, Grok.gutter)
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
            let prompt = text.isEmpty ? String(loc: "Here is a file:") + "\n\n" + body
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
                    vm.errorMessage = String(loc: "Grok does not run /\(name) from here.")
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

    /// One word. The menu behind the chip spells the policy out in full; the chip
    /// only has to say which of the three you are on, and "Auto-approve" became
    /// "Automatisch genehmigen" in German, which is wider than the composer.
    private var approvalLabel: LocalizedStringKey {
        switch vm.approvalPolicy {
        case "all":   return "Auto"
        case "reads": return "Reads"
        // Not "Ask": the box directly above this chip already says "Ask Grok
        // anything", and the two words meant entirely different things.
        default:      return "Ask me"
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
                ListSectionLabel("Carried over")
            }
            Text("This session starts with a summary of the previous conversation. Grok receives it automatically with your first message. Nothing to paste.")
                .font(Grok.sans(14)).foregroundStyle(Grok.textDim).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                    Text(expanded ? "Hide the summary" : "Read the summary")
                        .font(Grok.sans(14, .medium))
                }
                .foregroundStyle(Grok.textDim)
                // Full width and a thumb tall to press, then the vertical growth comes
                // back out of the layout so the card keeps its 10pt rhythm.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .padding(.vertical, -12)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(summary)
                    .font(Grok.sans(14)).foregroundStyle(Grok.textDim).lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Grok.bg)
                    .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
            }
        }
        .padding(Grok.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous)
            .stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
        // The transcript already sits on the gutter; a second one here put this card
        // 16pt inside the action strip above it and the composer below it.
        .padding(.top, 12)
    }
}

struct TypingIndicator: View {
    @State private var animating = false
    var body: some View {
        // No label above it: a reply has no header either, so the dots simply appear
        // where the reply will.
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Grok.text)
                    .frame(width: 7, height: 7)
                    .opacity(animating ? 0.95 : 0.25)
                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.16), value: animating)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .onAppear { animating = true }
        .accessibilityElement()
        .accessibilityLabel(Text("Grok is thinking"))
    }
}

/// Grok's reasoning, as a trace you can open rather than a wall you have to scroll
/// past. It stays open while the thinking is live — that is the interesting part —
/// and folds itself to "Thought for 12s" the moment an answer starts.
/// Grok reasoning out loud.
///
/// While it is live this is the only thing on screen that is moving, and it used to
/// move like a text file being appended to: the label sat still, the seconds were
/// invisible until the end, and the trace grew downward without bound until the
/// answer pushed it off. Now the label shimmers while it is thinking, the elapsed
/// seconds tick, and the trace runs in a window pinned to its newest line, which is
/// the line worth reading.
struct ThoughtTrace: View {
    let item: ChatItem
    var highlight: String = ""
    @State private var expanded = true

    private var live: Bool { item.endedAt == nil }
    /// Tall enough for four or five lines. Beyond that a live trace is scrollback,
    /// and scrollback belongs to the conversation, not to the thing still running.
    private let liveWindow: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Haptics.tap()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Grok.textDim)
                        .symbolEffect(.variableColor.iterative, isActive: live)
                        .accessibilityHidden(true)
                    header
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Grok.textFaint)
                        // One glyph that turns, rather than two that swap: a swap
                        // cannot be animated and read as a flicker.
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(alignment: .top, spacing: 12) {
                    Capsule()
                        .fill(live
                              ? AnyShapeStyle(LinearGradient(
                                  colors: [Grok.hairlineStrong.opacity(0), Grok.hairlineStrong],
                                  startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Grok.hairlineStrong))
                        .frame(width: 2)
                    trace
                }
                .frame(maxHeight: live ? liveWindow : nil, alignment: .bottom)
                .clipped()
                .mask(live ? AnyView(topFade) : AnyView(Color.black))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Each streamed chunk changes the height; easing that is the difference
        // between a trace that is being written and one that is being redrawn.
        .animation(.easeOut(duration: 0.18), value: item.text)
        // Fold as soon as the answer starts: by then the reasoning is history and the
        // reply is what someone is waiting to read.
        .onChange(of: item.endedAt) { _, ended in
            guard ended != nil else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { expanded = false }
        }
        .onAppear { expanded = live }
    }

    private var trace: some View {
        Text(ChatBubble.marking(AttributedString(item.text), query: highlight))
            .font(Grok.sans(15))
            .foregroundStyle(Grok.textDim)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The window shows the newest lines; the older ones fade out of the top rather
    /// than being cut off by a hard edge.
    private var topFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: .black, location: 0.28),
                               .init(color: .black, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private var header: some View {
        if let seconds = item.thoughtDuration {
            Text("Thought for \(Int(seconds.rounded()))s")
                .font(Grok.sans(15, .medium))
                .foregroundStyle(Grok.textDim)
        } else if let since = item.startedAt {
            // Ticking, because "Thinking" on its own looks the same after four
            // seconds and after four minutes.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ShimmerLabel(
                    Text("Thinking \(Int(context.date.timeIntervalSince(since).rounded()))s"))
            }
            .accessibilityLabel(Text("Thinking"))
        } else {
            ShimmerLabel(Text("Thinking"))
        }
    }
}

/// A highlight that sweeps across the glyphs, for the one label on screen that is
/// meant to look busy.
struct ShimmerLabel: View {
    private let label: Text
    @State private var phase: CGFloat = -1
    init(_ label: Text) { self.label = label }

    var body: some View {
        label
            .font(Grok.sans(15, .medium))
            .foregroundStyle(Grok.textFaint)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Grok.text, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                // Masked to the text, so the sweep lights the letters rather than
                // painting a band across the row.
                .mask(label.font(Grok.sans(15, .medium)))
                .allowsHitTesting(false)
            }
            .onAppear {
                phase = -0.6
                withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
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
                                    .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairlineStrong, lineWidth: 1))
                            }
                        }
                    } else if item.imageCount > 0 {
                        // Replayed history: the pixels stayed on the computer.
                        HStack(spacing: 5) {
                            Image(systemName: "photo").font(.system(size: 10, weight: .semibold))
                            Text("\(item.imageCount) image\(item.imageCount == 1 ? "" : "s") attached")
                        }
                        .font(Grok.sans(13, .medium))
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
            ThoughtTrace(item: item, highlight: highlight)

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
            .padding(Grok.pad)
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
                    .font(Grok.sans(11, .medium)).latinTracking(0.6).foregroundStyle(Grok.textFaint)
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
        .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
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
                        // A 13pt label is a 16pt tall target on the control that opens
                        // what a tool actually did. Pad it out to a thumb, then take the
                        // vertical growth back out of the layout so a tool line with
                        // output stays exactly as tall as one without.
                        .padding(.vertical, 13).padding(.leading, 12)
                        .contentShape(Rectangle())
                        .padding(.vertical, -13)
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
        .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
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
                        .font(Grok.sans(13, .medium)).foregroundStyle(Grok.textDim)
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
                Text(verbatim: "⋯").font(Grok.sans(14)).foregroundStyle(Grok.textFaint)
                    .frame(width: 10, alignment: .leading)
                    .accessibilityHidden(true)
                // Stand in for the line-number column, so the folded-lines label starts
                // on the same left edge as the code above and below it.
                Color.clear.frame(width: 26, height: 1)
                    .accessibilityHidden(true)
                (row.hidden == 1 ? Text("1 unchanged line") : Text("\(row.hidden) unchanged lines"))
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
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
        case .added: return String(loc: "Added: \(row.text)")
        case .removed: return String(loc: "Removed: \(row.text)")
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
    /// A long command is clipped to four lines so the buttons stay on screen; tap the
    /// command to see all of it.
    @State private var expanded = false

    private var denyOptions: [PermissionOption] { item.options.filter { !$0.isAllow } }
    /// What this command does that is worth a second look. Computed once per card.
    private var risk: CommandRisk? { CommandRisk.assess(item.text) }

    /// The whole card is one decision, so it is laid out as one: what is being asked,
    /// then yes or no on a single line, then the two rarer answers as plain text.
    /// It used to stack four full-height pills, which made the buttons taller than the
    /// command they were about.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Text(ChatBubble.marking(AttributedString(item.text), query: highlight))
                .font(Grok.mono(13))
                .foregroundStyle(Grok.text)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }

            // The reason a command is worth a second look reads as a line under it,
            // not as a boxed banner inside a boxed card.
            if let risk {
                Text(risk.reason)
                    .font(Grok.sans(13))
                    .foregroundStyle(risk.level == .destructive ? Grok.danger : Grok.textDim)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let decided = item.decided {
                Text(outcomeLabel(decided))
                    .font(Grok.sans(15, .semibold))
                    .foregroundStyle(Grok.textDim)
            } else if explaining, let deny = denyOptions.first {
                explainBox(deny)
            } else {
                actions
            }
        }
        .padding(Grok.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous)
            .stroke(risk?.level == .destructive ? Grok.danger.opacity(0.40) : Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
    }

    /// One line: what kind of thing this is, and what about it is worth noticing.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Grok.textFaint)
                .accessibilityHidden(true)
            ListSectionLabel("Permission")
            Spacer(minLength: 8)
            if let risk {
                HStack(spacing: 5) {
                    Image(systemName: risk.icon).font(.system(size: 10, weight: .semibold))
                    Text(risk.label)
                        .font(Grok.sans(10, .bold)).latinTracking(0.6)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(risk.level == .destructive ? Grok.danger : Grok.textDim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((risk.level == .destructive ? Grok.danger : Color.white).opacity(0.12))
                .clipShape(Capsule())
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Yes and no share a row; the two answers you reach for less often sit under it
    /// as text. `ViewThatFits` keeps that honest in German and at large type sizes,
    /// where the same two labels need two lines.
    @ViewBuilder private var actions: some View {
        let allow = item.options.first(where: { $0.isAllow })
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if let deny = denyOptions.first {
                    Button { onDecide(deny.optionId, false, nil) } label: { Text(deny.name) }
                        .buttonStyle(PillButton(kind: .subtle, compact: true))
                }
                if let allow {
                    Button { onDecide(allow.optionId, false, nil) } label: { Text(allow.name) }
                        .buttonStyle(PillButton(kind: .prominent, compact: true))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { alwaysAllowButton(allow); Spacer(minLength: 12); explainButton }
                VStack(alignment: .leading, spacing: 0) { alwaysAllowButton(allow); explainButton }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // A request can carry more than the usual two answers. The extras belong
            // behind one control rather than as two more pills nobody reads.
            if denyOptions.count > 1 {
                Menu {
                    ForEach(denyOptions.dropFirst()) { opt in
                        Button(opt.name) { onDecide(opt.optionId, false, nil) }
                    }
                } label: {
                    Text("Other answers").font(Grok.sans(13, .medium)).foregroundStyle(Grok.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private func alwaysAllowButton(_ allow: PermissionOption?) -> some View {
        if let allow {
            Button {
                // Destructive commands do not get a one-tap "and every one after
                // this, unattended".
                if risk?.level == .destructive { confirmAlways = true }
                else { onDecide(allow.optionId, true, nil) }
            } label: {
                Label("Always allow", systemImage: "bolt.fill")
            }
            .buttonStyle(QuietButton())
            .confirmationDialog("Approve everything from now on?", isPresented: $confirmAlways, titleVisibility: .visible) {
                Button("Always allow", role: .destructive) { onDecide(allow.optionId, true, nil) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This session will stop asking, including for commands like this one that delete or overwrite things.")
            }
        }
    }

    @ViewBuilder private var explainButton: some View {
        if !denyOptions.isEmpty {
            Button {
                explaining = true
                reasonFocused = true
            } label: {
                Label("Deny & explain", systemImage: "text.bubble")
            }
            .buttonStyle(QuietButton())
        }
    }

    /// Deny, and say why in the same breath. The text is queued as the next message,
    /// so Grok reads the correction instead of guessing at a bare refusal.
    @ViewBuilder private func explainBox(_ deny: PermissionOption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $reason,
                      prompt: Text("why not? e.g. use the staging database instead")
                          .foregroundColor(Grok.textFaint),
                      axis: .vertical)
                // A sentence addressed to Grok, not a command: the reading face, the
                // way the composer above sets the message you are writing.
                .font(Grok.sans(15))
                .foregroundStyle(Grok.text)
                .lineLimit(1...4)
                .focused($reasonFocused)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Grok.bg)
                .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
                .accessibilityLabel("Reason for denying")

            // The same two-compact-pills row the card's main answers use, with the
            // vertical fallback for the type sizes where "Refuser et envoyer" beside
            // "Retour" would otherwise shrink to a different point size than its
            // neighbour and then truncate.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { backButton; sendDenialButton(deny) }
                VStack(spacing: 8) { backButton; sendDenialButton(deny) }
            }
        }
    }

    private var backButton: some View {
        Button { explaining = false; reason = "" } label: { Text("Back") }
            .buttonStyle(PillButton(kind: .subtle, compact: true))
    }

    private func sendDenialButton(_ deny: PermissionOption) -> some View {
        Button {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            onDecide(deny.optionId, false, trimmed.isEmpty ? nil : trimmed)
        } label: {
            Text("Deny & send")
        }
        .buttonStyle(PillButton(kind: .prominent, compact: true))
    }

    private func outcomeLabel(_ optionId: String) -> String {
        if optionId == "cancelled" { return String(loc: "· cancelled ·") }
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
                VStack(alignment: .leading, spacing: Grok.groupGap) {
                    context
                    tokens
                    technical
                    exportSection
                }
                .padding(.horizontal, Grok.gutter).padding(.vertical, 20)
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
            ListSectionLabel("Export")
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
            ListSectionLabel("Context window")
            if u.contextWindow > 0 {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(verbatim: "\(Int(u.contextFraction * 100))")
                        .font(Grok.display(34)).tracking(-1).monospacedDigit()
                        .foregroundStyle(u.contextFraction > 0.85 ? Grok.danger : Grok.text)
                    Text(verbatim: "%").font(Grok.sans(17, .medium)).foregroundStyle(Grok.textDim)
                    Spacer(minLength: 0)
                    Text("\(Fmt.tokens(u.contextTokens)) / \(Fmt.tokens(u.contextWindow))")
                        .font(Grok.sans(14)).monospacedDigit().foregroundStyle(Grok.textDim)
                }
                UsageBar(fraction: u.contextFraction)
                Text("\(Fmt.tokens(u.contextRemaining)) left")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
            } else {
                Text("Send a message to see context usage.")
                    .font(Grok.sans(14)).foregroundStyle(Grok.textFaint)
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
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
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
                Text("Starts a second session that already knows everything this one knows, for trying another approach without losing this one.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
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
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
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
            branchError = String(loc: "Couldn't branch this session. Check the connection and try again.")
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
            // A bare literal here never reaches the string table: the sentence shipped
            // in English to all seven translations, and to English in its uncorrected
            // wording. Same shape as `branch()` above.
            compactError = String(loc: "Compaction failed. Check the connection and try again.")
        }
    }

    private var tokens: some View {
        VStack(alignment: .leading, spacing: 12) {
            ListSectionLabel("This session")
            HStack(alignment: .top, spacing: 0) {
                Readout(value: Fmt.tokens(u.totalTokens), label: "Tokens")
                Spacer(minLength: 12)
                Readout(value: "\(u.turns)", label: "Turns")
                Spacer(minLength: 12)
                Readout(value: Fmt.cost(u.costUSD), label: "Est. cost")
                Spacer(minLength: 0)
            }
            Rectangle().fill(Grok.rule).frame(height: 1)
            row("Input", Fmt.tokens(u.inputTokens))
            row("Output", Fmt.tokens(u.outputTokens))
            row("Thinking", Fmt.tokens(u.reasoningTokens))
            row("Cached read", Fmt.tokens(u.cachedReadTokens))
            row("Compute time", Fmt.duration(u.apiDurationMs))
            Text("Cost is grok's own reported estimate.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
        }
    }

    private var technical: some View {
        VStack(alignment: .leading, spacing: 12) {
            ListSectionLabel("Technical")
            row("Model", u.lastModelId.isEmpty ? (session.model?.isEmpty == false ? session.model! : String(loc: "grok default")) : u.lastModelId)
            row("Reasoning effort", effortText)
            row("Plan mode", vm.planMode ? String(loc: "on") : String(loc: "off"))
            row("Approvals", approvalText)
            row("Transport", session.transport ?? "acp")
            row("Directory", session.cwd.map { ($0 as NSString).lastPathComponent } ?? "-")
            row("Session ID", String(session.id.prefix(8)))
        }
    }

    /// Both of these have to say what the composer's chips say. They used to print the
    /// raw wire value, which is English in every language, and "" was reported as
    /// "auto" for a session that is in fact running high.
    private var effortText: String {
        switch vm.effort {
        case "medium": return String(loc: "Medium")
        case "low":    return String(loc: "Low")
        default:       return String(loc: "High")
        }
    }

    /// Three states, not two: a session set to approve reads only read as "off" here
    /// while its chip in the composer was lit.
    private var approvalText: String {
        switch vm.approvalPolicy {
        case "all":   return String(loc: "Auto")
        case "reads": return String(loc: "Reads")
        default:      return String(loc: "Ask")
        }
    }

    private func row(_ k: LocalizedStringKey, _ v: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(k).font(Grok.sans(15)).foregroundStyle(Grok.textDim)
                Spacer()
                Text(v).font(Grok.sans(15)).monospacedDigit()
                    .foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
            }
            .padding(.vertical, 7)
            Rectangle().fill(Grok.rule).frame(height: 1)
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
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(fraction > 0.85 ? Grok.danger : Grok.accent)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
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
                ListSectionLabel("Plan")
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
                (decided == "approved" ? Text("✓ Approved, building") : Text("✗ Kept planning"))
                    .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.textDim)
            } else {
                VStack(spacing: 8) {
                    Button { onDecide(true) } label: { Text("Approve & build").frame(maxWidth: .infinity) }
                        .buttonStyle(PillButton(kind: .prominent))
                    Button { onDecide(false) } label: { Text("Keep planning").frame(maxWidth: .infinity) }
                        .buttonStyle(PillButton(kind: .subtle))
                }
            }
        }
        .padding(Grok.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous)
            .stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
    }
}

/// Widths of the composer's chip row and of the space it is given, so the row can
/// tell whether it actually needs a scroll affordance.
private struct ChipsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChipsViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
