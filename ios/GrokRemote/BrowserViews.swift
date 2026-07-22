import SwiftUI

// MARK: - Working-directory picker

/// Browse the computer's folders (home-jailed on the bridge) instead of typing a
/// Unix path on a phone keyboard. Recent project folders — from existing sessions —
/// are one tap.
struct DirectoryPickerSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var listing: DirListing?
    @State private var loading = true
    @State private var errorText: String?
    @State private var query = ""
    @State private var results: [DirListing.Dir]?
    @State private var searching = false

    /// Unique cwds of existing sessions, newest first — the "just take me back
    /// to my project" path.
    private var recents: [String] {
        var seen = Set<String>()
        return app.sessions.compactMap { $0.cwd }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchField
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResults
                    } else {
                        if let listing {
                            currentFolder(listing)
                        } else if loading {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("reading folders…").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if let errorText {
                            HStack(alignment: .top, spacing: 8) {
                                Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
                                Text(errorText).font(Grok.mono(12)).foregroundStyle(Grok.danger)
                            }
                        }
                        if listing?.parent == nil, !recents.isEmpty { recentsSection }
                    }
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .navigationTitle("Working directory")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Grok.textDim)
                }
            }
            .task { await load(nil) }
            // Debounced folder-name search across the whole home directory.
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2, let client = app.client else { results = nil; return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                searching = true
                defer { searching = false }
                let found = try? await client.searchDirs(q)
                // A cancelled fetch (user kept typing) must not clobber the results
                // with a bogus "no folders match".
                guard !Task.isCancelled else { return }
                results = found ?? []
            }
        }
        .preferredColorScheme(.dark)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Grok.textFaint)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text("search folders by name").foregroundColor(Grok.textFaint))
                .font(Grok.mono(13)).foregroundStyle(Grok.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if searching { ProgressView().controlSize(.mini).tint(Grok.textFaint) }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Grok.textDim)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var searchResults: some View {
        if let results {
            if results.isEmpty, !searching {
                Text("// no folders match")
                    .font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.path) { i, dir in
                        if i > 0 { Rectangle().fill(Grok.hairline).frame(height: 1) }
                        Button {
                            app.defaultCwd = dir.path
                            Haptics.success()
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Grok.textDim)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dir.name).font(Grok.mono(13)).foregroundStyle(Grok.text).lineLimit(1)
                                    Text(dir.path).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
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
        } else if searching {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text("searching…").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func currentFolder(_ l: DirListing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("THIS FOLDER")
            Text(l.path)
                .font(Grok.mono(12)).foregroundStyle(Grok.text)
                .lineLimit(1).truncationMode(.head)
            Button {
                app.defaultCwd = l.path
                Haptics.success()
                dismiss()
            } label: {
                Label("Use this folder", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButton(kind: .prominent))
        }

        VStack(alignment: .leading, spacing: 0) {
            if let parent = l.parent {
                row(name: "..", icon: "arrow.turn.left.up") { Task { await load(parent) } }
                Rectangle().fill(Grok.hairline).frame(height: 1)
            }
            if l.dirs.isEmpty {
                Text("// no subfolders")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                    .padding(.vertical, 14).padding(.horizontal, 14)
            }
            ForEach(l.dirs) { d in
                row(name: d.name, icon: "folder") { Task { await load(d.path) } }
                if d.id != l.dirs.last?.id { Rectangle().fill(Grok.hairline).frame(height: 1) }
            }
        }
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("RECENT PROJECTS")
            ForEach(recents.prefix(6), id: \.self) { cwd in
                Button {
                    app.defaultCwd = cwd
                    Haptics.success()
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(Grok.textDim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((cwd as NSString).lastPathComponent).font(Grok.mono(13)).foregroundStyle(Grok.text)
                            Text(cwd).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Grok.raised)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(name: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Grok.textDim).frame(width: 16)
                Text(name).font(Grok.mono(13)).foregroundStyle(Grok.text).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Grok.textFaint)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load(_ path: String?) async {
        loading = true
        errorText = nil
        defer { loading = false }
        guard let client = app.client else { errorText = "Not connected."; return }
        do { listing = try await client.listDirs(path: path) }
        catch { errorText = (error as? BridgeError)?.errorDescription ?? error.localizedDescription }
    }
}

// MARK: - Project file browser (read-only)

/// Browse the session's working directory and read files — see the project, not
/// just the diffs.
struct FileBrowserSheet: View {
    let client: BridgeClient
    let session: SessionInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FileFolderScreen(client: client, sessionId: session.id, relPath: "",
                             title: session.cwd.map { ($0 as NSString).lastPathComponent } ?? "Files")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.foregroundStyle(Grok.text).fontWeight(.semibold)
                    }
                }
                .navigationDestination(for: BrowsePath.self) { dest in
                    if dest.isFile {
                        FileViewerScreen(client: client, sessionId: session.id, relPath: dest.path)
                    } else {
                        FileFolderScreen(client: client, sessionId: session.id, relPath: dest.path,
                                         title: (dest.path as NSString).lastPathComponent)
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// A navigable location inside the project tree.
struct BrowsePath: Hashable {
    var path: String
    var isFile: Bool
}

struct FileFolderScreen: View {
    let client: BridgeClient
    let sessionId: String
    let relPath: String
    let title: String

    @State private var entries: [FileEntry]?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let entries {
                    if entries.isEmpty {
                        Text("// empty folder").font(Grok.mono(12)).foregroundStyle(Grok.textFaint).padding(16)
                    }
                    ForEach(entries) { e in
                        NavigationLink(value: BrowsePath(path: relPath.isEmpty ? e.name : relPath + "/" + e.name, isFile: !e.dir)) {
                            HStack(spacing: 10) {
                                Image(systemName: e.dir ? "folder.fill" : "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundStyle(e.dir ? Grok.textDim : Grok.textFaint)
                                    .frame(width: 18)
                                Text(e.name).font(Grok.mono(13)).foregroundStyle(Grok.text).lineLimit(1)
                                Spacer(minLength: 0)
                                if !e.dir { Text(sizeLabel(e.size)).font(Grok.mono(10)).foregroundStyle(Grok.textFaint) }
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Grok.textFaint)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if e.id != entries.last?.id {
                            Rectangle().fill(Grok.hairline).frame(height: 1).padding(.leading, 16)
                        }
                    }
                } else if let errorText {
                    HStack(alignment: .top, spacing: 8) {
                        Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
                        Text(errorText).font(Grok.mono(12)).foregroundStyle(Grok.danger)
                    }
                    .padding(16)
                } else {
                    ProgressView().controlSize(.small).tint(.white).padding(20)
                }
            }
        }
        .background(Grok.bg)
        .scrollIndicators(.hidden)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .grokBar()
        .task {
            do { entries = try await client.listFiles(sessionId: sessionId, path: relPath) }
            catch { errorText = (error as? BridgeError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func sizeLabel(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1_024 { return String(format: "%.0f KB", Double(n) / 1_024) }
        return "\(n) B"
    }
}

struct FileViewerScreen: View {
    let client: BridgeClient
    let sessionId: String
    let relPath: String

    @State private var file: FileContent?
    @State private var errorText: String?

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            if let file {
                if file.binary {
                    Text("// binary file · \(file.size) bytes")
                        .font(Grok.mono(11)).foregroundStyle(Grok.textFaint).padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(file.content ?? "")
                            .font(Grok.mono(12))
                            .foregroundStyle(Grok.text)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(14)
                        if file.truncated == true {
                            Text("… truncated — the full file is \(file.size) bytes")
                                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                                .padding(.horizontal, 14).padding(.bottom, 12)
                        }
                    }
                }
            } else if let errorText {
                Text(errorText).font(Grok.mono(12)).foregroundStyle(Grok.danger).padding(16)
            } else {
                ProgressView().controlSize(.small).tint(.white).padding(20)
            }
        }
        .background(Grok.bg)
        .navigationTitle((relPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .grokBar()
        .toolbar {
            if let content = file?.content, !content.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = content
                        Haptics.tap()
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Grok.textDim)
                    .accessibilityLabel(Text("Copy file contents"))
                }
            }
        }
        .task {
            do { file = try await client.fileContent(sessionId: sessionId, path: relPath) }
            catch { errorText = (error as? BridgeError)?.errorDescription ?? error.localizedDescription }
        }
    }
}
