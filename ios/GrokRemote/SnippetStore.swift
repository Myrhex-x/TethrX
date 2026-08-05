import Foundation

/// A reusable prompt written on the phone.
///
/// Prompts are the part of TethrX that works with nothing paired: you can write,
/// dictate, edit and organise them with no computer at all, and tap one into the
/// composer once a computer is connected.
struct Prompt: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var text: String
    var updatedAt: Date = Date()

    /// First non-empty line — the row title in the library.
    var title: String {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything after the title, for the second row line.
    var body: String {
        let rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 != "\n" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.replacingOccurrences(of: "\n", with: " ")
    }
}

/// On-device library of reusable prompts: the standalone workspace on the welcome
/// screen, the tappable row above the chat composer, and a Settings entry point.
/// Persisted to UserDefaults as JSON.
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var items: [Prompt] = [] { didSet { persist() } }

    private static let key = "prompt.library"
    private static let legacyKey = "prompt.snippets"

    /// Plain strings, for the composer row and anything else that only wants text.
    var texts: [String] { items.map(\.text) }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Prompt].self, from: data) {
            items = saved
        } else if let legacy = d.array(forKey: Self.legacyKey) as? [String], !legacy.isEmpty {
            // Carry over the flat string list written by builds before the library.
            items = legacy.map { Prompt(text: $0) }
            persist()
        } else {
            items = Self.starters.map { Prompt(text: String(localized: $0)) }
            persist()   // writing the key now is what stops a fully emptied library re-seeding
        }
    }

    /// Seeds for a brand-new install. Localized, so the first thing someone sees in
    /// their own language is usable text rather than English placeholders.
    private static let starters: [String.LocalizationValue] = [
        "Run the tests and fix any failures.",
        "Commit the changes with a clear message.",
        "Explain what this file does.",
        "Review your changes for bugs.",
    ]

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Add a prompt at the top. Returns nil when it's blank or already there, so
    /// callers can tell "saved" from "nothing to do".
    @discardableResult
    func add(_ s: String) -> Prompt? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !items.contains(where: { $0.text == t }) else { return nil }
        let prompt = Prompt(text: t)
        items.insert(prompt, at: 0)
        return prompt
    }

    func update(_ id: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = t
        items[i].updatedAt = Date()
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }
    }

    /// Offsets come from a view that may have rendered against a longer list, so
    /// drop any that no longer exist instead of trapping.
    func remove(at offsets: IndexSet) {
        let valid = IndexSet(offsets.filter { items.indices.contains($0) })
        guard !valid.isEmpty else { return }
        items.remove(atOffsets: valid)
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Case-insensitive substring search over the whole prompt text.
    func matching(_ query: String) -> [Prompt] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
}
