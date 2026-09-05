import SwiftUI

/// The launch screen when no computer is connected.
///
/// Deliberately a working screen rather than a setup checklist: the prompt
/// library below is fully usable on its own, the tour walks the whole app with
/// no hardware, and connecting a computer is one clearly-labelled step among
/// them — not a wall you have to climb before the app does anything.
struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var snippets: SnippetStore

    @State private var pairing = false
    @State private var library = false
    @State private var creating = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    /// The computer this phone last paired with, when there is one.
    private var savedName: String? {
        guard !app.token.isEmpty, !app.normalizedBase.isEmpty else { return nil }
        if let id = app.activeBridgeId, let b = app.savedBridges.first(where: { $0.id == id }) { return b.name }
        return app.savedBridges.first?.name ?? URL(string: app.normalizedBase)?.host
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let savedName { reconnectCard(savedName) }
                    actions
                    promptsCard
                    if let err = app.errorMessage { errorRow(err) }
                    footer
                }
                .padding(.horizontal, Grok.gutter).padding(.vertical, 24)
                .padding(.top, 12)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(isPresented: $pairing) { PairingView() }
        }
        .sheet(isPresented: $library) { PromptLibraryView().environmentObject(snippets) }
        .sheet(isPresented: $creating) { PromptEditor(prompt: nil).environmentObject(snippets) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                TethrXMark(size: 30)
                    .frame(width: 52, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairlineStrong, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("TETHRX")
                    Text("Your coding tasks, in your pocket")
                        .font(Grok.sans(20, .semibold)).latinTracking(-0.3).foregroundStyle(Grok.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Write and keep the tasks you want run, right here. Connect your own computer whenever you want them carried out by Grok Build on it.")
                .font(Grok.sans(14)).foregroundStyle(Grok.textDim).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Primary actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button { app.enterDemo() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "play.circle").font(.system(size: 15, weight: .medium))
                    Text("Take the tour")
                }
            }
            .buttonStyle(PillButton(kind: .prominent))
            .accessibilityHint(Text("Walks through the whole app using sample data, with no computer needed"))

            Button { pairing = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "desktopcomputer").font(.system(size: 14, weight: .medium))
                    Text("Connect a computer")
                }
            }
            .buttonStyle(PillButton(kind: .subtle))
        }
    }

    // MARK: Prompts — the part that works with nothing connected

    private var promptsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("YOUR PROMPTS")
                Spacer(minLength: 8)
                Button { library = true } label: {
                    HStack(spacing: 4) {
                        Text(snippets.items.isEmpty ? "Open" : "All \(snippets.items.count)")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(Grok.sans(14, .medium)).foregroundStyle(Grok.textDim)
                }
                .buttonStyle(.plain)
            }

            Text("Kept on this phone. Tap one into any session once a computer is connected.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                FieldBox {
                    TextField("", text: $draft,
                              prompt: Text("write a task…").foregroundColor(Grok.textFaint),
                              axis: .vertical)
                        .font(Grok.sans(16)).foregroundStyle(Grok.text).lineLimit(1...4)
                        .focused($draftFocused)
                }
                CircleIconButton(system: "plus", filled: !isBlankDraft, enabled: !isBlankDraft,
                                 a11y: String(localized: "Save prompt")) {
                    snippets.add(draft)
                    draft = ""
                    draftFocused = false
                    Haptics.success()
                }
            }

            ForEach(snippets.items.prefix(3)) { prompt in
                Button { library = true } label: { PromptRow(prompt: prompt) }
                    .buttonStyle(.plain)
            }

            Button { creating = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .medium))
                    Text("Write a longer prompt")
                }
                .font(Grok.sans(15, .medium)).foregroundStyle(Grok.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(Grok.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
    }

    private var isBlankDraft: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Reconnect

    private func reconnectCard(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 14)).foregroundStyle(Grok.textDim)
                Text("Welcome back").font(Grok.sans(16, .semibold)).foregroundStyle(Grok.text)
            }
            Text("This phone is already paired with \(name).")
                .font(Grok.sans(14)).foregroundStyle(Grok.textFaint).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                draftFocused = false
                Haptics.tap()
                Task { await app.connect() }
            } label: {
                HStack(spacing: 9) {
                    if app.connecting {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .bold))
                    }
                    (app.connecting ? Text("Reconnecting…") : Text("Reconnect")).latinTracking(0.3)
                }
            }
            .buttonStyle(PillButton(kind: .prominent))
            .disabled(app.connecting)
        }
        .padding(Grok.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
    }

    // MARK: Chrome

    private func errorRow(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("!").font(Grok.sans(15, .bold)).foregroundStyle(Grok.danger)
            Text(err).font(Grok.sans(15)).foregroundStyle(Grok.danger).lineSpacing(2)
        }
    }

    private var footer: some View {
        Text("A client for Grok Build · independent, not affiliated with xAI")
            .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }
}
