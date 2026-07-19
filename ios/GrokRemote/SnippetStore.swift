import Foundation

/// On-device library of reusable prompts, shown above the composer and managed
/// in Settings. Persisted to UserDefaults.
@MainActor
final class SnippetStore: ObservableObject {
    @Published var items: [String] {
        didSet { UserDefaults.standard.set(items, forKey: "prompt.snippets") }
    }

    init() {
        if let saved = UserDefaults.standard.array(forKey: "prompt.snippets") as? [String] {
            items = saved
        } else {
            items = [
                "Run the tests and fix any failures.",
                "Commit the changes with a clear message.",
                "Explain what this file does.",
                "Review your changes for bugs.",
            ]
        }
    }

    func add(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !items.contains(t) else { return }
        items.append(t)
    }

    func remove(at offsets: IndexSet) { items.remove(atOffsets: offsets) }
}
