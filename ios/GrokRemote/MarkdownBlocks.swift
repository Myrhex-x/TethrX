import SwiftUI

/// Block-level Markdown for Grok's replies: headings, lists, quotes, rules and tables.
///
/// Replies used to go through `AttributedString`'s inline-only parser, which is the
/// right tool for **bold** and `code` and the wrong one for everything else Grok
/// writes. A plan arrived as "## Goal" and "- step" with the hashes and hyphens
/// printed literally, and a comparison table as rows of pipes. Those are the long
/// replies, which are exactly the ones that most need to be easy to read.
///
/// Fenced code is split out before this runs (`ChatBubble.segments`), so a block here
/// never contains a fence. The parser is line-based and forgiving on purpose: it runs
/// on every streamed chunk, so a half-written table or list has to render as
/// something sensible rather than flicker between shapes.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case item(ListItem)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])

    struct ListItem: Equatable {
        /// 0 for a top-level item, 1 for one nested under it, and so on.
        var depth: Int
        /// "•" for bullets, "3." for numbered items, nil for a task item.
        var marker: String?
        /// Set for `- [ ]` / `- [x]` items.
        var checked: Bool?
        var text: String
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        let lines = source.components(separatedBy: "\n")

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushAll() { flushParagraph(); flushQuote() }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushAll()
                i += 1
                continue
            }

            // A table is a header row, a separator row, then rows. Without the
            // separator a line of pipes is just text (shell pipelines contain them).
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushAll()
                let header = cells(of: trimmed)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let row = lines[j].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(of: row))
                    j += 1
                }
                blocks.append(.table(header: header, rows: rows))
                i = j
                continue
            }

            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var body = String(trimmed.dropFirst())
                if body.hasPrefix(" ") { body.removeFirst() }
                quote.append(body)
                i += 1
                continue
            }

            if let item = listItem(line) {
                flushAll()
                blocks.append(.item(item))
                i += 1
                continue
            }

            // A plain line straight after a list item, indented, continues that
            // item (a wrapped bullet); anything else starts or extends a paragraph.
            if case .item(var last)? = blocks.last, paragraph.isEmpty, quote.isEmpty,
               line.hasPrefix("  ") || line.hasPrefix("\t") {
                last.text += " " + trimmed
                blocks[blocks.count - 1] = .item(last)
                i += 1
                continue
            }

            flushQuote()
            paragraph.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        // "#hashtag" is not a heading; "# Title" is. A bare "##" mid-stream is a
        // heading still being typed, and showing it empty beats showing the hashes.
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        let depth = min(indent / 2, 4)

        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            var text = String(body.dropFirst(2))
            var checked: Bool?
            if text.hasPrefix("[ ] ") { checked = false; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { checked = true; text.removeFirst(4) }
            return ListItem(depth: depth, marker: checked == nil ? "•" : nil, checked: checked, text: text)
        }

        let digits = body.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let punct = after.first, punct == "." || punct == ")", after.dropFirst().first == " " {
                return ListItem(depth: depth, marker: "\(digits).", checked: nil,
                                text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(of row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Renders one prose segment of a reply as blocks.
struct MarkdownBlocksView: View {
    let text: String
    var highlight: String = ""
    @Environment(\.readingScale) private var scale

    private var bodySize: CGFloat { 17 * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { index, block in
                view(for: block, first: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ s: String) -> AttributedString {
        ChatBubble.marking(ChatBubble.markdown(s), query: highlight)
    }

    @ViewBuilder private func view(for block: MarkdownBlock, first: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            let size = bodySize * (level == 1 ? 1.32 : level == 2 ? 1.18 : level == 3 ? 1.06 : 1.0)
            Text(inline(text))
                .font(Grok.sans(size, level <= 2 ? .bold : .semibold))
                .foregroundStyle(Grok.text)
                .lineSpacing(2)
                .textSelection(.enabled)
                // Space above a heading is what makes it start a section rather than
                // label the line before it.
                .padding(.top, first ? 0 : (level <= 2 ? 10 : 6))
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            Text(inline(text))
                .font(Grok.sans(bodySize))
                .foregroundStyle(Grok.text)
                .lineSpacing(ReadingSize.lineSpacing(for: bodySize))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .item(let item):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if let checked = item.checked {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: bodySize * 0.82))
                            .foregroundStyle(checked ? Grok.textDim : Grok.textFaint)
                    } else {
                        Text(verbatim: item.marker ?? "•")
                            .font(Grok.sans(bodySize, item.marker == "•" ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(Grok.textDim)
                    }
                }
                // Markers share one column, so "9." and "10." line their text up.
                .frame(minWidth: item.marker == "•" || item.checked != nil ? 12 : 22, alignment: .trailing)
                .accessibilityHidden(item.marker == "•")
                Text(inline(item.text))
                    .font(Grok.sans(bodySize))
                    .foregroundStyle(item.checked == true ? Grok.textDim : Grok.text)
                    .strikethrough(item.checked == true, color: Grok.textFaint)
                    .lineSpacing(ReadingSize.lineSpacing(for: bodySize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(item.depth) * 20)

        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                Capsule().fill(Grok.hairlineStrong).frame(width: 3)
                Text(inline(text))
                    .font(Grok.sans(bodySize))
                    .foregroundStyle(Grok.textDim)
                    .lineSpacing(ReadingSize.lineSpacing(for: bodySize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle().fill(Grok.hairline).frame(height: 1).padding(.vertical, 6)

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, size: bodySize * 0.88, highlight: highlight)
        }
    }
}

/// A Markdown table as a real grid, scrolling sideways when it is wider than the
/// phone rather than wrapping every cell into a column of single words.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let size: CGFloat
    let highlight: String

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(c < header.count ? header[c] : "", bold: true)
                    }
                }
                .background(Grok.raised)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(Grok.hairline)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(c < row.count ? row[c] : "", bold: false)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous)
                .stroke(Grok.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
        }
    }

    private func cell(_ s: String, bold: Bool) -> some View {
        Text(ChatBubble.marking(ChatBubble.markdown(s), query: highlight))
            .font(Grok.sans(size, bold ? .semibold : .regular))
            .foregroundStyle(bold ? Grok.text : Grok.text.opacity(0.92))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(minWidth: 72, maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
