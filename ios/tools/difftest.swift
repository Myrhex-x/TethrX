// Checks for UnifiedDiff, the alignment behind the transcript's file diffs.
//
// The app has no test target, and DiffModel.swift deliberately imports Foundation
// only, so this compiles and runs on its own:
//
//   swiftc -O -o /tmp/difftest ios/tools/difftest.swift ios/GrokRemote/DiffModel.swift
//   /tmp/difftest
//
// CI runs exactly that.

@main
enum DiffTest {
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print(condition ? "ok   \(what)" : "FAIL \(what)")
        if !condition { failures += 1 }
    }

    static func main() {
        // A one-line insertion in the middle of a file.
        let before = (1...20).map { "line \($0)" }
        var after = before
        after.insert("inserted", at: 10)
        var result = UnifiedDiff.build(old: before, new: after)
        expect(result.added == 1 && result.removed == 0, "single insert counts +1/-0")
        expect(result.rows.contains { $0.kind == .gap }, "distant context is folded away")
        expect(result.rows.filter { $0.kind == .context }.count == 6, "three lines of context each side")

        // A one-for-one replacement marks only the characters that changed.
        result = UnifiedDiff.build(old: ["let timeout = 30", "print(timeout)"],
                                   new: ["let timeout = 60", "print(timeout)"])
        expect(result.added == 1 && result.removed == 1, "replacement counts +1/-1")
        let removed = result.rows.first { $0.kind == .removed }
        expect(removed?.emphasis == 14..<15,
               "emphasis spans only the digit that changed, got \(String(describing: removed?.emphasis))")

        // Identical input produces nothing at all: grok emits this for a no-op edit.
        result = UnifiedDiff.build(old: ["a", "b"], new: ["a", "b"])
        expect(result.rows.isEmpty && result.added == 0 && result.removed == 0, "no diff for identical text")

        // Creating a file, and emptying one.
        result = UnifiedDiff.build(old: [], new: ["a", "b", "c"])
        expect(result.added == 3 && result.removed == 0, "a new file is all additions")
        result = UnifiedDiff.build(old: ["a", "b", "c"], new: [])
        expect(result.removed == 3 && result.added == 0, "an emptied file is all removals")

        // Numbering: a removed line keeps its old number, everything else reads
        // against the file as it now stands.
        result = UnifiedDiff.build(old: ["a", "b", "c"], new: ["a", "x", "c"])
        let numbers = result.rows.map { row -> String in
            switch row.kind {
            case .removed: return "-\(row.oldNumber ?? -1)"
            case .added:   return "+\(row.newNumber ?? -1)"
            case .context: return " \(row.newNumber ?? -1)"
            case .gap:     return "..."
            }
        }
        expect(numbers == [" 1", "-2", "+2", " 3"], "numbering reads as one run, got \(numbers)")

        // A rewrite too large to align falls back to a wholesale replacement rather
        // than building a 640,000-cell table on a phone.
        let big = (1...800).map { "old \($0)" }
        let bigger = (1...800).map { "new \($0)" }
        result = UnifiedDiff.build(old: big, new: bigger)
        expect(result.coarse, "an 800 by 800 rewrite is coarse")
        expect(result.added == 800 && result.removed == 800, "a coarse diff still counts both sides")

        print(failures == 0 ? "\nall diff checks passed" : "\n\(failures) FAILURES")
        if failures > 0 { exit(1) }
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
