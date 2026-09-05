import SwiftUI

/// One step of the checklist Grok keeps while it works.
///
/// Grok has always sent this over ACP — content plus a status that moves from
/// pending to in progress to completed. The app used to keep only the text, and
/// append a fresh bullet list to the transcript on every revision, so a ten-step
/// task left ten near-identical dumps behind and never showed which step was live.
struct PlanEntry: Equatable, Identifiable {
    var id: Int
    var content: String
    var status: String       // "pending" | "in_progress" | "completed"

    var isDone: Bool { status == "completed" }
    var isActive: Bool { status == "in_progress" }

    /// Decode ACP's plan entries, tolerating a missing or unknown status.
    static func decode(_ raw: [[String: Any]]) -> [PlanEntry] {
        raw.enumerated().compactMap { index, entry in
            guard let content = entry["content"] as? String, !content.isEmpty else { return nil }
            let status = (entry["status"] as? String) ?? "pending"
            return PlanEntry(id: index, content: content, status: status)
        }
    }
}

extension Array where Element == PlanEntry {
    var completedCount: Int { filter(\.isDone).count }
    /// The step Grok says it is on, else the first one still to do.
    var activeIndex: Int? {
        firstIndex(where: \.isActive) ?? firstIndex(where: { !$0.isDone })
    }
    var allDone: Bool { !isEmpty && completedCount == count }
}

// MARK: - The card in the transcript

/// Grok's checklist, updating in place: what is done, what it is on now, what is
/// left. One card per turn, not one per revision.
struct TaskListCard: View {
    let entries: [PlanEntry]
    /// Non-empty while the chat's find bar is open.
    var highlight: String = ""
    @State private var expanded = false

    /// Long plans collapse to the live step and its neighbours; the rest is one tap away.
    private static let collapsedLimit = 5

    private var shown: [PlanEntry] {
        guard !expanded, entries.count > Self.collapsedLimit else { return entries }
        // Keep the window around whatever is happening now, so a 20-step plan doesn't
        // show its first five forever.
        let active = entries.activeIndex ?? 0
        let start = Swift.max(0, Swift.min(active - 1, entries.count - Self.collapsedLimit))
        return Array(entries[start..<Swift.min(entries.count, start + Self.collapsedLimit)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 9) {
                ForEach(shown) { entry in row(entry) }
            }
            if entries.count > Self.collapsedLimit {
                Button {
                    Haptics.tap()
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .accessibilityHidden(true)
                        (expanded ? Text("Show fewer steps") : Text("Show all \(entries.count) steps"))
                            .font(Grok.sans(14, .medium))
                    }
                    .foregroundStyle(Grok.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: entries.allDone ? "checklist.checked" : "checklist")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Grok.accent)
                    .accessibilityHidden(true)
                Eyebrow("PLAN", comment: false)
                Spacer(minLength: 0)
                Text(verbatim: "\(entries.completedCount)/\(entries.count)")
                    .font(Grok.sans(14, .semibold)).foregroundStyle(Grok.textDim)
                    .monospacedDigit()
            }
            UsageBar(fraction: entries.isEmpty ? 0 : Double(entries.completedCount) / Double(entries.count))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Plan, \(entries.completedCount) of \(entries.count) steps done"))
    }

    private func row(_ entry: PlanEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(glyph(entry))
                .font(Grok.sans(14, .bold))
                .foregroundStyle(entry.isDone ? Grok.textFaint : Grok.accent)
                .frame(width: 12, alignment: .leading)
                .accessibilityHidden(true)
            Text(ChatBubble.marking(AttributedString(entry.content), query: highlight))
                .font(Grok.mono(12, entry.isActive ? .semibold : .regular))
                .foregroundStyle(entry.isDone ? Grok.textFaint : (entry.isActive ? Grok.text : Grok.textDim))
                .strikethrough(entry.isDone, color: Grok.textFaint)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(entry.isDone ? "Done: \(entry.content)"
                                 : (entry.isActive ? "In progress: \(entry.content)" : "To do: \(entry.content)")))
    }

    private func glyph(_ entry: PlanEntry) -> String {
        if entry.isDone { return "✓" }
        if entry.isActive { return "▸" }
        return "○"
    }
}

// MARK: - The pill in the chat's action strip

/// "3/7 steps" beside the session's buttons, so the plan's position is visible
/// without scrolling back to the card.
struct PlanProgressPill: View {
    let entries: [PlanEntry]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist").font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: "\(entries.completedCount)/\(entries.count)").monospacedDigit()
        }
        .font(Grok.sans(14, .medium))
        .foregroundStyle(Grok.textDim)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(Capsule().stroke(Grok.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Plan, \(entries.completedCount) of \(entries.count) steps done"))
    }
}
