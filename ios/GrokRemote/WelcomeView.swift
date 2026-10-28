import SwiftUI

/// The launch screen when no computer is connected.
///
/// Deliberately a working screen rather than a setup checklist: the prompt
/// library below is fully usable on its own, the tour walks the whole app with
/// no hardware, and connecting a computer is one clearly-labelled step among
/// them — not a wall you have to climb before the app does anything.
///
/// A native grouped list, like the home screen and Settings it leads to: the
/// first screen someone sees should already look like the rest of the app.
struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var snippets: SnippetStore

    @State private var pairing = false
    @State private var library = false
    @State private var creating = false
    @State private var editing: Prompt?
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
            List {
                Section { header }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
                if let savedName {
                    Section { reconnectRow(savedName) }
                }
                Section { actions }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                promptsSection
                if let err = app.errorMessage {
                    Section {
                        Text(err).font(.subheadline).foregroundStyle(Grok.danger)
                    }
                }
                Section {} footer: {
                    Text("A client for Grok Build · independent, not affiliated with xAI")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(isPresented: $pairing) { PairingView() }
        }
        #if DEBUG
        // Headless screenshots: `-openLibrary` opens the prompt library sheet.
        .task { if ProcessInfo.processInfo.arguments.contains("-openLibrary") { library = true } }
        #endif
        .sheet(isPresented: $library) { PromptLibraryView().environmentObject(snippets) }
        .sheet(isPresented: $creating) { PromptEditor(prompt: nil).environmentObject(snippets) }
        .sheet(item: $editing) { PromptEditor(prompt: $0).environmentObject(snippets) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                TethrXMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TethrX").font(.subheadline.weight(.semibold)).foregroundStyle(Grok.textDim)
                    Text("Your coding tasks, in your pocket")
                        .font(.title3.weight(.semibold)).foregroundStyle(Grok.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Write and keep the tasks you want run, right here. Connect your own computer whenever you want them carried out by Grok Build on it.")
                .font(.subheadline).foregroundStyle(Grok.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Reconnect

    private func reconnectRow(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RowIcon(system: "desktopcomputer")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome back").font(.headline).foregroundStyle(Grok.text)
                    Text("This phone is already paired with \(name).")
                        .font(.subheadline).foregroundStyle(Grok.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                draftFocused = false
                Haptics.tap()
                Task { await app.connect() }
            } label: {
                HStack(spacing: 9) {
                    if app.connecting {
                        ProgressView().controlSize(.small).tint(Grok.onInk)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .bold))
                    }
                    app.connecting ? Text("Reconnecting…") : Text("Reconnect")
                }
            }
            .buttonStyle(PillButton(kind: .prominent))
            .disabled(app.connecting)
        }
        .padding(.vertical, 8)
    }

    // MARK: Primary actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button { app.enterDemo() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "play.circle").font(.system(size: 15, weight: .medium))
                    Text("Take the tour")
                }
            }
            // One black button per screen. With a computer already paired, the black
            // one is Reconnect above; two stacked primaries said nothing about which
            // was the way in.
            .buttonStyle(PillButton(kind: savedName == nil ? .prominent : .subtle))
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

    private var promptsSection: some View {
        Section {
            HStack(spacing: 10) {
                TextField("", text: $draft,
                          prompt: Text("write a task…").foregroundColor(Grok.placeholder),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .focused($draftFocused)
                Button {
                    _ = snippets.add(draft)
                    draft = ""
                    draftFocused = false
                    Haptics.success()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isBlankDraft ? Grok.textFaint : Grok.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isBlankDraft)
                .accessibilityLabel(Text("Save prompt"))
            }
            .padding(.vertical, -4)

            ForEach(snippets.items.prefix(3)) { prompt in
                Button { editing = prompt } label: { PromptRow(prompt: prompt) }
                    .buttonStyle(RowPressStyle())
                    .listRowInsets(EdgeInsets())
            }

            Button { creating = true } label: {
                Label("Write a longer prompt", systemImage: "square.and.pencil")
            }
        } header: {
            HStack {
                Text("Your prompts")
                Spacer(minLength: 8)
                Button { library = true } label: {
                    HStack(spacing: 3) {
                        Text(snippets.items.isEmpty ? "Open" : "All \(snippets.items.count)")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
            .textCase(nil)
        } footer: {
            Text("Kept on this phone. Tap one into any session once a computer is connected.")
        }
    }

    private var isBlankDraft: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
