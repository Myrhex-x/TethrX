import SwiftUI
import UIKit

/// Owns a conversation's model for the life of its screen. `@StateObject` builds it
/// once (its value is an autoclosure), and this never publishes anything itself:
/// what each view reads from the model is tracked by SwiftUI's observation.
final class ChatModelHolder: ObservableObject {
    let vm: ChatViewModel
    init(_ vm: ChatViewModel) { self.vm = vm }
}

/// The conversation itself: every item, the follow-the-tail scrolling, and the
/// buttons that hover over it.
///
/// Its own view so that it is the only thing a streamed word re-renders, and so the
/// composer below it can be typed into without re-rendering it. `Equatable` on the
/// inputs that change what it draws; the model's own changes reach it through
/// observation.
struct ChatTranscript: View, Equatable {
    let vm: ChatViewModel
    let finding: Bool
    let findQuery: String
    /// Set to an item's id to bring it into view (find in conversation).
    let scrollTarget: UUID?
    /// Bumped to pull the transcript to its end whatever the reader was doing: on
    /// send, the thing to look at is the message just sent.
    let followRequest: Int
    let readingScale: CGFloat
    /// Extra horizontal inset that caps the line length on wide screens.
    let measureInset: CGFloat
    /// Puts text in the composer and focuses it (Edit & resend, the starters).
    let onDraft: (String) -> Void

    @State private var atBottom = true
    /// When the reader last dragged the transcript themselves.
    @State private var lastUserScroll = Date.distantPast

    static func == (a: ChatTranscript, b: ChatTranscript) -> Bool {
        a.vm === b.vm && a.finding == b.finding && a.findQuery == b.findQuery
            && a.scrollTarget == b.scrollTarget && a.followRequest == b.followRequest
            && a.readingScale == b.readingScale && a.measureInset == b.measureInset
    }

    private let bottomID = "bottom"
    private var lastText: String { vm.items.last?.text ?? "" }

    /// Show the animated "grok is thinking" dots while busy and no text is streaming yet.
    private var showTyping: Bool {
        guard vm.busy else { return false }
        switch vm.items.last?.role {
        case .assistant, .thought: return false
        default: return true
        }
    }

    var body: some View {
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
                            // Filling the viewport keeps the openers where the eye
                            // lands rather than in a short block above a void.
                            blankSession.frame(minHeight: max(0, outer.size.height - 56))
                        }
                        ForEach(vm.items) { item in
                            switch item.role {
                            case .permission:
                                PermissionCard(item: item, folder: vm.session.cwd,
                                               highlight: finding ? findQuery : "") { optionId, always, reason in
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
                                                onDraft(item.text)
                                            } label: {
                                                Label("Edit & resend", systemImage: "arrow.uturn.left")
                                            }
                                        }
                                    }
                            }
                        }
                        if showTyping { TypingIndicator().id("typing") }
                        if let retry = vm.retry { RetryLine(retry: retry).id("retry") }
                        Color.clear.frame(height: 1).id(bottomID)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomOffsetKey.self,
                                                       value: g.frame(in: .named("transcript")).minY)
                            })
                    }
                    // A reading measure on iPad and in landscape: a reply set the full
                    // width of a 13" screen is a line the eye cannot track back from.
                    .padding(.horizontal, Grok.gutter + measureInset).padding(.vertical, 18)
                }
                .environment(\.readingScale, readingScale)
                .coordinateSpace(name: "transcript")
                // No `defaultScrollAnchor(.bottom)`. Together with the scroll to the
                // end below, it left the transcript blank at the accessibility text
                // sizes: the anchor placed the view on an estimated bottom where the
                // lazy stack had laid nothing out, and the end never came into view.
                // The explicit scroll alone lands on the end at every size.
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in lastUserScroll = Date() })
                .onPreferenceChange(BottomOffsetKey.self) { minY in
                    // The sentinel is not rendered at all, which means we are scrolled
                    // well away from the bottom, not at it.
                    let bottom = minY != .greatestFiniteMagnitude && minY <= outer.size.height + 80
                    if bottom {
                        if !atBottom { atBottom = true }
                    } else if atBottom {
                        // Only the reader scrolling up releases the transcript. Anything
                        // else that pushes the end out of view (a table landing in one
                        // piece, the keyboard, the usage line growing the title bar as
                        // a turn ends) is layout, and the tail is brought back instead.
                        // Each of those used to end following and leave the last line
                        // of a reply under the composer.
                        if Date().timeIntervalSince(lastUserScroll) < 1.0 {
                            atBottom = false
                        } else if !finding {
                            DispatchQueue.main.async { scrollToBottom(proxy) }
                        }
                    }
                }
                // While the find bar is open the reader is looking at a match, not at
                // the tail: a streaming turn must not drag them back down.
                // Open on the end of the conversation. Messages already loaded on the
                // first frame change nothing, so nothing else would bring it there.
                .onAppear { DispatchQueue.main.async { if atBottom, !finding { scrollToBottom(proxy) } } }
                .onChange(of: vm.items.count) { _, _ in contentGrew(proxy) }
                .onChange(of: lastText) { _, _ in contentGrew(proxy) }
                .onChange(of: vm.busy) { _, _ in contentGrew(proxy) }
                .onChange(of: followRequest) { _, _ in
                    atBottom = true
                    scrollToBottom(proxy, animated: true)
                }
                // The keyboard takes half the screen. The transcript used to keep its
                // offset and lose its tail behind the keyboard, so the message you had
                // just sent, and the reply to it, happened out of sight.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    if atBottom, !finding { scrollToBottom(proxy) }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    // Jumping to a match is the reader choosing a place to read.
                    atBottom = false
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
            TethrXMark(size: 44, color: Grok.ink.opacity(0.12))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)
            ListSectionLabel("Start with").padding(.bottom, 2)
            ForEach(starters.indices, id: \.self) { i in
                let text = String(loc: starters[i])
                Button {
                    onDraft(text)
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
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(item.id, anchor: .center) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
                Text("Waiting for you").font(Grok.sans(15, .semibold))
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Grok.onInk)
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
            atBottom = true
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

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            // Unanimated while a reply streams: a 150ms animation retargeted every
            // 50ms never finishes, which read as the transcript stuttering.
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    /// The transcript grew (a new item, more streamed text, a state change). Keep the
    /// tail in view when the reader was at it.
    private func contentGrew(_ proxy: ScrollViewProxy) {
        if atBottom, !finding { scrollToBottom(proxy) }
    }
}
