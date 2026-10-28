import SwiftUI
import UIKit

/// The on-device prompt library: write, dictate, edit and organise the tasks you
/// want to hand to Grok Build. Everything here works with no computer paired —
/// it's the app's standalone workspace, and the same prompts appear above the
/// chat composer once a computer is connected.
struct PromptLibraryView: View {
    @EnvironmentObject var snippets: SnippetStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var editing: Prompt?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            let results = snippets.matching(query)
            List {
                if !results.isEmpty {
                    Section {
                        ForEach(results) { prompt in
                            Button { editing = prompt } label: { PromptRow(prompt: prompt) }
                                .buttonStyle(RowPressStyle())
                                .listRowInsets(EdgeInsets())
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation { snippets.delete(prompt.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    } footer: {
                        if query.isEmpty {
                            Text("Write the tasks you want run, whenever they occur to you. They're kept on this phone, and you can tap one into any session later.")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if results.isEmpty { emptyState }
            }
            // The system search field, in the bar where every Apple list keeps it.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Search"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Prompts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(Text("New prompt"))
                }
            }
        }
        .grokScheme()
        .sheet(isPresented: $creating) { PromptEditor(prompt: nil) }
        .sheet(item: $editing) { PromptEditor(prompt: $0) }
    }

    @ViewBuilder private var emptyState: some View {
        if query.isEmpty {
            ContentUnavailableView {
                Label("No prompts yet", systemImage: "square.and.pencil")
            } description: {
                Text("Write the tasks you want run, whenever they occur to you. They're kept on this phone, and you can tap one into any session later.")
            } actions: {
                Button { creating = true } label: { Text("Write your first prompt") }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        } else {
            // The system's own "No Results" page, worded and translated by iOS.
            ContentUnavailableView.search(text: query)
        }
    }
}

// MARK: - Row

struct PromptRow: View {
    let prompt: Prompt

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title).font(.body).foregroundStyle(Grok.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if !prompt.body.isEmpty {
                    Text(prompt.body).font(.subheadline).foregroundStyle(Grok.textDim).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            RowChevron()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Editor

/// Write or edit one prompt. `prompt == nil` composes a new one.
struct PromptEditor: View {
    let prompt: Prompt?

    @EnvironmentObject var snippets: SnippetStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dictation = Dictation()
    @State private var text: String
    @State private var confirmingDelete = false
    @FocusState private var focused: Bool

    init(prompt: Prompt?) {
        self.prompt = prompt
        _text = State(initialValue: prompt?.text ?? "")
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $text)
                    .font(Grok.sans(17))
                    .foregroundStyle(Grok.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .focused($focused)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Run the tests and fix any failures…")
                                .font(Grok.sans(17)).foregroundStyle(Grok.textFaint)
                                .padding(.horizontal, 21).padding(.top, 20)
                                .allowsHitTesting(false)
                        }
                    }
                toolbar
            }
            .background(Grok.bg)
            .navigationTitle(prompt == nil ? "New prompt" : "Edit prompt")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { stopDictation(); dismiss() }.foregroundStyle(Grok.textDim)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .foregroundStyle(trimmed.isEmpty ? Grok.textFaint : Grok.text)
                        .fontWeight(.semibold)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        .grokScheme()
        .onAppear { if prompt == nil { focused = true } }
        .onDisappear { stopDictation() }
        .onChange(of: dictation.transcript) { _, v in if dictation.isRecording { text = v } }
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
        .confirmationDialog("Delete this prompt?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let prompt { snippets.delete(prompt.id) }
                stopDictation()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            if dictation.supported {
                Button { dictation.toggle(base: text) } label: {
                    Image(systemName: dictation.isRecording ? "waveform" : "mic")
                        .font(.system(size: 15))
                        .foregroundStyle(dictation.isRecording ? Grok.accent : Grok.textDim)
                        .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                .accessibilityHint(Text("Long-press to change the dictation language"))
                .contextMenu {
                    Section("Dictation language: \(dictation.currentLanguageLabel)") {
                        ForEach(Dictation.languageChoices, id: \.id) { choice in
                            Button {
                                dictation.localeId = choice.id
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

            Button {
                UIPasteboard.general.string = trimmed
                Haptics.tap()
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 14)).foregroundStyle(Grok.textDim)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
            .accessibilityLabel(Text("Copy"))

            ShareLink(item: trimmed) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 14)).foregroundStyle(Grok.textDim)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(trimmed.isEmpty)
            .accessibilityLabel(Text("Share"))

            Spacer(minLength: 0)

            if prompt != nil {
                Button { confirmingDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(Grok.danger)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Delete"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .overlay(alignment: .top) { Rectangle().fill(Grok.hairline).frame(height: 1) }
    }

    private func save() {
        stopDictation()
        if let prompt {
            snippets.update(prompt.id, text: text)
        } else {
            snippets.add(text)
        }
        Haptics.success()
        dismiss()
    }

    /// The recogniser keeps firing partials after the view goes away, and each one
    /// writes back into `text` — stop it on every exit, not just Save.
    private func stopDictation() {
        if dictation.isRecording { dictation.stop() }
    }
}
