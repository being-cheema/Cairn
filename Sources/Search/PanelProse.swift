import SwiftUI

// Claude's answer, set as text: headings, lists, tables, quotes and code, by
// the Mac's own Markdown for what is inside a line.
//
// An answer is made from pages, and a page can try to make Claude write
// anything. So the rule the plain panel had stays: there is nothing in an
// answer to follow and nothing it can make the app fetch. Every link is taken
// out of the text and its site written after it in words, so that "your bank"
// can't quietly point somewhere else; a picture is only its description. The
// one thing that can be pressed is Copy on a block of code, and a pill that
// goes to a tab you already have open.

enum PanelProse {
    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        /// One line of a list: its mark as shown ("•", "3."), how deep.
        case item(String, Int, String)
        case quote(String)
        case code(String, String)
        case table([String], [[String]])
        case rule
    }

    // MARK: - lines into blocks

    static func blocks(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                // A fence still being written has no end yet: all of it is code.
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                out.append(.code(language, code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush()
                out.append(heading)
            } else if trimmed.count >= 3, Set(trimmed).count == 1, "-*_".contains(trimmed.first ?? " ") {
                flush()
                out.append(.rule)
            } else if trimmed.hasPrefix("|"), i + 1 < lines.count, divides(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i])
                    row += Array(repeating: "", count: max(header.count - row.count, 0))
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                out.append(.table(header, rows))
                continue
            } else if let item = item(line) {
                flush()
                out.append(item)
            } else if trimmed.hasPrefix(">") {
                flush()
                let said = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let before) = out.last {
                    out[out.count - 1] = .quote(before + "\n" + said)
                } else {
                    out.append(.quote(said))
                }
            } else {
                paragraph.append(trimmed)
            }
            i += 1
        }
        flush()
        return out
    }

    private static func heading(_ line: String) -> Block? {
        let marks = line.prefix { $0 == "#" }.count
        guard (1...6).contains(marks), line.dropFirst(marks).first == " " else { return nil }
        return .heading(marks, String(line.dropFirst(marks + 1)))
    }

    private static func item(_ line: String) -> Block? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        let depth = min(indent / 2, 3)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .item("•", depth, String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let after = rest.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 3, after.first == "." || after.first == ")", after.dropFirst().first == " " {
            return .item("\(digits).", depth, String(after.dropFirst(2)))
        }
        return nil
    }

    private static func divides(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        return t.replacingOccurrences(of: "\\|", with: "\u{1}").components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - inside a line

    /// Bold, italics and code; links and pictures made into words.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: untabbed(text), options: options) else {
            return AttributedString(text)
        }
        var out = AttributedString()
        var link: URL?
        var words = ""
        func close() {
            // Where it pointed, unless the words already say.
            if let link {
                let host = link.host()?.lowercased() ?? link.scheme ?? ""
                // Named whole: "banana.com" doesn't say a.co.
                let whole = "(?<![a-z0-9.\\-])" + NSRegularExpression.escapedPattern(for: host) + "(?![a-z0-9\\-]|\\.[a-z0-9])"
                if !host.isEmpty, words.lowercased().range(of: whole, options: .regularExpression) == nil {
                    out += AttributedString(" (\(host))")
                }
            }
            link = nil
            words = ""
        }
        for run in parsed.runs {
            if run.link != link { close() }
            var piece = AttributedString(parsed[run.range])
            link = run.link
            if link != nil { words += String(piece.characters) }
            piece.link = nil
            piece.imageURL = nil
            out += piece
        }
        close()
        return out
    }

    // MARK: - tabs pointed at

    /// The titles named as [Tab: title], in the order first named.
    static func tabsNamed(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[Tab: "), let close = rest.range(of: "]", range: open.upperBound..<rest.endIndex) {
            let title = String(rest[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty, title.count <= 200, !title.contains("\n"), !out.contains(title) { out.append(title) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// The same words with each [Tab: title] as just the title.
    private static func untabbed(_ text: String) -> String {
        var out = text
        for title in tabsNamed(in: text) { out = out.replacingOccurrences(of: "[Tab: \(title)]", with: "“\(title)”") }
        return out
    }
}

/// An answer's blocks, one under another.
struct ProseView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(PanelProse.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ text: String, size: CGFloat = 13, weight: Font.Weight = .regular) -> some View {
        Text(PanelProse.inline(text))
            .font(.system(size: size, weight: weight))
            .foregroundStyle(Palette.ink)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func view(_ block: PanelProse.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            line(text, size: level == 1 ? 16 : level == 2 ? 14.5 : 13, weight: .semibold)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            line(text)
        case .item(let mark, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: mark).font(.system(size: 13)).foregroundStyle(Palette.muted)
                line(text)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote(let text):
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 1).fill(Palette.hairline).frame(width: 2)
                line(text)
            }
        case .rule:
            Rectangle().fill(Palette.hairline).frame(height: 1)
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .table(let header, let rows):
            ProseTable(header: header, rows: rows)
        }
    }

    private struct CodeBlock: View {
        let language: String
        let code: String
        @State private var copied = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: language.isEmpty ? "Code" : language)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    Quick(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: code)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(10)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// A table that scrolls sideways when the panel is too narrow for it.
struct ProseTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in text(cell, .semibold) }
                }
                Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in text(cell, .regular) }
                    }
                }
            }
            .padding(10)
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func text(_ cell: String, _ weight: Font.Weight) -> some View {
        Text(PanelProse.inline(cell))
            .font(.system(size: 12, weight: weight))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: 180, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
