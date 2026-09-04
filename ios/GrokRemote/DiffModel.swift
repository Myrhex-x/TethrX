import Foundation

/// Turns a before/after pair into a real unified diff.
///
/// The transcript used to print every old line, then every new line, one block under
/// the other. For grok's usual edit — three lines changed inside forty — that meant
/// reading two nearly identical walls and spotting the difference yourself. This
/// interleaves them, keeps a few lines of context, folds away the rest, and marks the
/// part of a changed line that actually changed.
enum UnifiedDiff {

    struct Row: Identifiable {
        enum Kind { case context, added, removed, gap }
        let id: Int
        let kind: Kind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
        /// For `.gap`: how many unchanged lines are folded away here.
        let hidden: Int
        /// Character range of the part that differs from the paired line, when this
        /// line is one half of a one-for-one replacement.
        let emphasis: Range<Int>?

        init(id: Int, kind: Kind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil,
             hidden: Int = 0, emphasis: Range<Int>? = nil) {
            self.id = id
            self.kind = kind
            self.text = text
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.hidden = hidden
            self.emphasis = emphasis
        }
    }

    struct Result {
        var rows: [Row] = []
        var added = 0
        var removed = 0
        /// The change was too large to align line by line, so it is shown as one
        /// wholesale replacement instead of a matched diff.
        var coarse = false
    }

    /// Unchanged lines kept either side of a change.
    static let context = 3
    /// Above this many cells the alignment table is not worth building on a phone;
    /// a rewrite that big reads as a replacement anyway.
    private static let maxCells = 400_000

    static func build(old: [String], new: [String], context: Int = UnifiedDiff.context) -> Result {
        // Identical: nothing to show. (Grok emits this for a no-op edit.)
        if old == new { return Result() }

        // Shared head and tail come off first. Grok's `search_replace` hands over a
        // whole region with a couple of lines changed in the middle, so this alone
        // usually shrinks the alignment problem to a handful of lines.
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }

        let oldMid = Array(old[head..<(old.count - tail)])
        let newMid = Array(new[head..<(new.count - tail)])

        var result = Result()
        let ops: [Op]
        if oldMid.count * newMid.count > maxCells {
            result.coarse = true
            ops = oldMid.map { Op.remove($0) } + newMid.map { Op.add($0) }
        } else {
            ops = script(oldMid, newMid)
        }

        // Re-attach the shared head and tail as context around the edit.
        var all: [Op] = old[0..<head].map { Op.keep($0) }
        all += ops
        all += old[(old.count - tail)...].map { Op.keep($0) }

        result.added = all.reduce(0) { $0 + ($1.isAdd ? 1 : 0) }
        result.removed = all.reduce(0) { $0 + ($1.isRemove ? 1 : 0) }
        result.rows = rows(from: all, context: context)
        return result
    }

    // MARK: Edit script

    private enum Op {
        case keep(String), add(String), remove(String)
        var isAdd: Bool { if case .add = self { return true }; return false }
        var isRemove: Bool { if case .remove = self { return true }; return false }
        var isKeep: Bool { if case .keep = self { return true }; return false }
    }

    /// Longest-common-subsequence alignment. Bounded by `maxCells` above, so the
    /// table is at most a megabyte and is built once per diff, never in `body`.
    private static func script(_ old: [String], _ new: [String]) -> [Op] {
        let n = old.count, m = new.count
        if n == 0 { return new.map { Op.add($0) } }
        if m == 0 { return old.map { Op.remove($0) } }

        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = old[i] == new[j]
                    ? table[(i + 1) * width + (j + 1)] + 1
                    : max(table[(i + 1) * width + j], table[i * width + (j + 1)])
            }
        }

        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                ops.append(.keep(old[i])); i += 1; j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + (j + 1)] {
                ops.append(.remove(old[i])); i += 1
            } else {
                ops.append(.add(new[j])); j += 1
            }
        }
        while i < n { ops.append(.remove(old[i])); i += 1 }
        while j < m { ops.append(.add(new[j])); j += 1 }
        return ops
    }

    // MARK: Rows

    /// Lay the script out as numbered rows, folding runs of untouched lines that are
    /// further than `context` from any change.
    private static func rows(from ops: [Op], context: Int) -> [Row] {
        // Which keeps are near enough to a change to be worth showing.
        var keep = [Bool](repeating: false, count: ops.count)
        for (index, op) in ops.enumerated() where !op.isKeep {
            let lower = max(0, index - context)
            let upper = min(ops.count - 1, index + context)
            for k in lower...upper { keep[k] = true }
        }

        var out: [Row] = []
        var oldLine = 0, newLine = 0
        var folded = 0
        var nextId = 0

        func flushGap() {
            guard folded > 0 else { return }
            out.append(Row(id: nextId, kind: .gap, text: "", hidden: folded))
            nextId += 1
            folded = 0
        }

        for (index, op) in ops.enumerated() {
            switch op {
            case .keep(let text):
                oldLine += 1; newLine += 1
                if keep[index] {
                    flushGap()
                    out.append(Row(id: nextId, kind: .context, text: text, oldNumber: oldLine, newNumber: newLine))
                    nextId += 1
                } else {
                    folded += 1
                }
            case .remove(let text):
                oldLine += 1
                flushGap()
                out.append(Row(id: nextId, kind: .removed, text: text, oldNumber: oldLine))
                nextId += 1
            case .add(let text):
                newLine += 1
                flushGap()
                out.append(Row(id: nextId, kind: .added, text: text, newNumber: newLine))
                nextId += 1
            }
        }
        flushGap()
        return emphasize(out)
    }

    /// Where exactly one removed line is replaced by exactly one added line, mark the
    /// span that actually differs so a one-character change is not a wall of two
    /// identical-looking lines.
    private static func emphasize(_ rows: [Row]) -> [Row] {
        var out = rows
        var index = 0
        while index < out.count {
            guard out[index].kind == .removed else { index += 1; continue }
            // A run of removals followed by a run of additions; only the clean 1-for-1
            // case can be aligned character by character with any confidence.
            var removedEnd = index
            while removedEnd < out.count, out[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < out.count, out[addedEnd].kind == .added { addedEnd += 1 }
            if removedEnd - index == 1, addedEnd - removedEnd == 1 {
                let before = Array(out[index].text)
                let after = Array(out[removedEnd].text)
                var prefix = 0
                while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < before.count - prefix, suffix < after.count - prefix,
                      before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
                // Only worth marking when the shared parts are the bulk of the line;
                // otherwise the "changed span" is the whole line and the marks add noise.
                let shared = prefix + suffix
                if shared > 0, shared * 2 >= min(before.count, after.count) {
                    out[index] = out[index].withEmphasis(prefix..<(before.count - suffix))
                    out[removedEnd] = out[removedEnd].withEmphasis(prefix..<(after.count - suffix))
                }
            }
            index = max(addedEnd, index + 1)
        }
        return out
    }
}

extension UnifiedDiff.Row {
    func withEmphasis(_ range: Range<Int>) -> UnifiedDiff.Row {
        guard !range.isEmpty else { return self }
        return UnifiedDiff.Row(id: id, kind: kind, text: text, oldNumber: oldNumber,
                               newNumber: newNumber, hidden: hidden, emphasis: range)
    }
}
