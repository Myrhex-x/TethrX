import SwiftUI

/// Review what Grok changed in this session's folder, then commit or discard —
/// so a remote run doesn't have to end with "I'll check it at my desk later".
struct GitReviewSheet: View {
    let client: BridgeClient
    let session: SessionInfo
    @Environment(\.dismiss) private var dismiss

    @State private var status: GitStatus?
    @State private var loading = true
    @State private var errorText: String?
    @State private var commitMessage = ""
    @State private var working = false
    @State private var confirmDiscard = false
    @State private var note: String?

    private var files: [GitFile] { status?.files ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("reading git…").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                        }
                    } else if status?.repo == false {
                        Text("// this session's folder isn't a git repository")
                            .font(Grok.mono(12)).foregroundStyle(Grok.textFaint)
                    } else if files.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No changes").font(Grok.sans(17, .semibold)).foregroundStyle(Grok.text)
                            Text("The working tree is clean\(status?.branch.map { " on \($0)" } ?? "").")
                                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                        }
                    } else {
                        header
                        fileList
                        commitBox
                        discardButton
                    }
                    if let note {
                        Text(note).font(Grok.mono(11)).foregroundStyle(Grok.textDim).lineSpacing(2)
                    }
                    if let errorText {
                        HStack(alignment: .top, spacing: 8) {
                            Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
                            Text(errorText).font(Grok.mono(12)).foregroundStyle(Grok.danger).lineSpacing(2)
                        }
                    }
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Grok.text).fontWeight(.semibold)
                }
            }
            .navigationDestination(for: GitFile.self) { file in
                GitDiffScreen(client: client, sessionId: session.id, file: file)
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .alert("Discard all changes?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { Task { await discard() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Reverts every modified file and deletes untracked ones in \(session.cwd ?? "this folder"). This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 12)).foregroundStyle(Grok.textDim)
            Text(status?.branch ?? "—").font(Grok.mono(12, .semibold)).foregroundStyle(Grok.text)
            Spacer()
            Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                if index > 0 { Rectangle().fill(Grok.hairline).frame(height: 1) }
                NavigationLink(value: file) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.filename).font(Grok.mono(13)).foregroundStyle(Grok.text).lineLimit(1)
                            if !file.folder.isEmpty {
                                Text(file.folder).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(file.label).font(Grok.mono(9, .medium)).tracking(0.5)
                            .foregroundStyle(Grok.textDim)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().stroke(Grok.hairline, lineWidth: 1))
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Grok.textFaint)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("COMMIT MESSAGE")
            FieldBox {
                TextField("", text: $commitMessage,
                          prompt: Text("what changed…").foregroundColor(Grok.textFaint), axis: .vertical)
                    .font(Grok.mono(13)).foregroundStyle(Grok.text)
                    .lineLimit(1...4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { Task { await commit() } } label: {
                HStack(spacing: 10) {
                    if working { ProgressView().controlSize(.small).tint(.white) }
                    (working ? Text("COMMITTING") : Text("COMMIT ALL")).tracking(1.3)
                }
            }
            .buttonStyle(PillButton(kind: .prominent))
            .disabled(working || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var discardButton: some View {
        Button { confirmDiscard = true } label: {
            Label("Discard all changes", systemImage: "trash")
        }
        .buttonStyle(PillButton(kind: .subtle))
        .disabled(working)
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do { status = try await client.gitStatus(sessionId: session.id) }
        catch { errorText = (error as? BridgeError)?.errorDescription ?? error.localizedDescription }
    }

    private func commit() async {
        working = true; errorText = nil; note = nil
        defer { working = false }
        do {
            let out = try await client.gitCommit(sessionId: session.id, message: commitMessage)
            Haptics.success()
            commitMessage = ""
            note = out.isEmpty ? "Committed." : out
            await load()
        } catch {
            errorText = "Commit failed. Check that git is configured (user.name / user.email) on that computer."
        }
    }

    private func discard() async {
        working = true; errorText = nil; note = nil
        defer { working = false }
        do {
            _ = try await client.gitDiscard(sessionId: session.id)
            Haptics.tap(.medium)
            note = "Changes discarded."
            await load()
        } catch {
            errorText = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Unified diff for one file, coloured like the inline tool diffs.
struct GitDiffScreen: View {
    let client: BridgeClient
    let sessionId: String
    let file: GitFile

    @State private var text = ""
    @State private var loading = true

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            if loading {
                ProgressView().controlSize(.small).tint(.white).padding(20)
            } else if text.isEmpty {
                Text("// no textual diff (binary file, or nothing to show)")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textFaint).padding(16)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(Grok.mono(11))
                            .foregroundStyle(color(for: line))
                            .padding(.horizontal, 12).padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line))
                    }
                }
                .padding(.vertical, 10)
                .textSelection(.enabled)
            }
        }
        .background(Grok.bg)
        .navigationTitle(file.filename)
        .navigationBarTitleDisplayMode(.inline)
        .grokBar()
        .task {
            defer { loading = false }
            text = (try? await client.gitDiff(sessionId: sessionId, file: file.path)) ?? ""
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return Grok.textFaint }
        if line.hasPrefix("@@") { return Grok.textDim }
        if line.hasPrefix("+") { return Grok.text }
        if line.hasPrefix("-") { return Grok.danger }
        return Grok.textDim
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Color.white.opacity(0.06) }
        if line.hasPrefix("-") { return Grok.danger.opacity(0.10) }
        return .clear
    }
}
