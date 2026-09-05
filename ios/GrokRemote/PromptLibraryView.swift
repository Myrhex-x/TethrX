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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Write the tasks you want run, whenever they occur to you. They're kept on this phone, and you can tap one into any session later.")
                        .font(Grok.sans(14)).foregroundStyle(Grok.textDim).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    searchField

                    let results = snippets.matching(query)
                    if results.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 10) {
                            ForEach(results) { prompt in
                                Button { editing = prompt } label: { PromptRow(prompt: prompt) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Prompts")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Grok.text).fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: {
                        Image(systemName: "square.and.pencil").fontWeight(.semibold)
                    }
                    .foregroundStyle(Grok.text)
                    .accessibilityLabel(Text("New prompt"))
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $creating) { PromptEditor(prompt: nil) }
        .sheet(item: $editing) { PromptEditor(prompt: $0) }
    }

    private var searchField: some View {
        FieldBox {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Grok.textFaint)
                TextField("", text: $query, prompt: Text("search prompts…").foregroundColor(Grok.textFaint))
                    .font(Grok.sans(16)).foregroundStyle(Grok.text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Grok.textFaint)
                            // A 13pt glyph was a 13pt target. The negative padding
                            // gives back the height the 44pt frame would otherwise
                            // add to the field, which is already 44pt tall.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .padding(.vertical, -13)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear search"))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "square.and.pencil" : "magnifyingglass")
                .font(.system(size: 22)).foregroundStyle(Grok.textFaint)
            (query.isEmpty ? Text("No prompts yet.") : Text("Nothing matches that."))
                .font(Grok.sans(15)).foregroundStyle(Grok.textDim)
            if query.isEmpty {
                Button { creating = true } label: { Text("Write your first prompt") }
                    .buttonStyle(PillButton(kind: .subtle))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

// MARK: - Row

struct PromptRow: View {
    let prompt: Prompt

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 11)).foregroundStyle(Grok.textFaint).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.title).font(Grok.sans(16)).foregroundStyle(Grok.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if !prompt.body.isEmpty {
                    Text(prompt.body).font(Grok.sans(14)).foregroundStyle(Grok.textFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Grok.textFaint)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .contentShape(RoundedRectangle(cornerRadius: 11))
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
        .preferredColorScheme(.dark)
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
