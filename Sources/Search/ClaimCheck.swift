import Foundation
import NaturalLanguage

// Looking for a result card's words in the pages it names as its sources.
//
// It matches text and nothing more. "Found" means these words and numbers are
// close together in what was read from that page, not that the claim is
// right; "not found in the source" means the match failed, not that the
// claim is wrong: a fair paraphrase fails, and so does a number written
// another way. It is said in those words, never as true or false.
//
// What was read is kept in memory only, with the chat: never written to
// disk, to Task History or to the log, and gone with New Chat.

/// The visible text an agent of the panel's read from its pages, by tab and
/// address, as its reads gave it.
struct SourceSnapshots: Equatable {
    struct Key: Hashable {
        let tab: UUID
        let page: String
    }

    struct Page: Equatable {
        /// By where each piece began: a long page is read in several.
        var pieces: [Int: String] = [:]
        /// How long the page's text was.
        var length = 0

        /// The pieces in order, and whether they are the whole of it.
        var read: (text: String, whole: Bool) {
            var out = "", reached = 0, gap = false
            for start in pieces.keys.sorted() {
                let piece = pieces[start] ?? ""
                if start > reached { gap = true; out += "\n" }
                // The page script counts as JavaScript does, in UTF-16.
                out += start < reached ? String(decoding: Array(piece.utf16.dropFirst(reached - start)), as: UTF16.self) : piece
                reached = max(reached, start + piece.utf16.count)
            }
            return (out, !gap && reached >= length)
        }
    }

    static let mostPages = 24, mostPerPage = 200_000

    private(set) var pages: [Key: Page] = [:]
    private var order: [Key] = []

    mutating func keep(_ text: String, at offset: Int, of length: Int, tab: UUID, page: String) {
        guard !text.isEmpty || length == 0 else { return }
        let key = Key(tab: tab, page: page)
        var kept = pages[key] ?? Page()
        // A page that changed length is another page: what was read of it
        // before is not part of it.
        if kept.length != length, offset == 0 { kept = Page() }
        kept.length = length
        let others = kept.pieces.filter { $0.key != offset }.values.reduce(0) { $0 + $1.utf16.count }
        guard others + text.utf16.count <= Self.mostPerPage else { return }
        kept.pieces[offset] = text
        pages[key] = kept
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.mostPages { pages[order.removeFirst()] = nil }
    }

    func page(tab: UUID, address: String) -> Page? { pages[Key(tab: tab, page: address)] }
}

enum ClaimCheck {
    enum Verdict: Equatable {
        case found
        case notFound
        /// Not in what was read, and only part of the page was.
        case notInPartRead
        /// The source's text isn't kept: it was never read there.
        case noText
        case noSource

        /// As the card says it.
        var words: String {
            switch self {
            case .found: "text found in the source"
            case .notFound: "not found in the source"
            case .notInPartRead: "not found in the part of the source that was read"
            case .noText: "no text of this source was kept"
            case .noSource: "no source named"
            }
        }
    }

    // MARK: - words

    /// Lower case, no accents, 1,200 as 1200, cut into words. A number is a
    /// word of its own, so that 5 is never found inside 15.
    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"(?<=\d),(?=\d{3}(?!\d))"#, with: "", options: .regularExpression)
        guard let numbers = try? NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#) else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        var out: [String] = []
        func words(_ part: Substring) {
            let part = String(part)
            tokenizer.string = part
            tokenizer.enumerateTokens(in: part.startIndex..<part.endIndex) { range, _ in
                let word = part[range].filter { $0.isLetter }
                if !word.isEmpty { out.append(String(word)) }
                return true
            }
        }
        var from = folded.startIndex
        for match in numbers.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)) {
            guard let range = Range(match.range, in: folded) else { continue }
            words(folded[from..<range.lowerBound])
            out.append(String(folded[range]))
            from = range.upperBound
        }
        words(folded[from...])
        return out
    }

    /// Words too common to count. "not", "no" and "never" are not among them.
    private static let common: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "from", "by", "with", "is", "are", "was",
        "were", "be", "been", "it", "its", "this", "that", "these", "those", "as", "has", "have", "had", "will", "can",
        "s", "per", "which", "their", "they", "also",
    ]
    /// Nothing to look for in these alone: any page has them.
    private static let empty: Set<String> = ["yes", "no", "none", "n", "unknown", "true", "false", "included", "free"]

    /// Whether `claim` has anything that could be looked for.
    static func checkable(_ claim: [String]) -> Bool {
        let words = claim.filter { !common.contains($0) }
        return !words.isEmpty && !(words.count == 1 && empty.contains(words[0]))
    }

    /// The claim's words as they stand, or else, within a stretch of the
    /// source not much longer than the claim, every one of its numbers, any
    /// "not" it has, and most of its other words (all, when they are few).
    static func matches(_ claim: [String], in source: [String]) -> Bool {
        guard !claim.isEmpty, !source.isEmpty else { return false }
        if (" " + source.joined(separator: " ") + " ").contains(" " + claim.joined(separator: " ") + " ") { return true }
        let wanted = Set(claim.filter { !common.contains($0) })
        guard !wanted.isEmpty else { return false }
        let must = wanted.filter { $0.first?.isNumber == true || ["not", "no", "never", "without"].contains($0) }
        let enough = wanted.count <= 4 ? wanted.count : Int((Double(wanted.count) * 0.8).rounded(.up))
        let span = max(24, claim.count * 2)
        var inside: [String: Int] = [:]
        var have = 0, needed = 0
        for (at, word) in source.enumerated() {
            if wanted.contains(word) {
                if inside[word, default: 0] == 0 { have += 1; if must.contains(word) { needed += 1 } }
                inside[word, default: 0] += 1
            }
            if at >= span {
                let gone = source[at - span]
                if wanted.contains(gone) {
                    inside[gone, default: 0] -= 1
                    if inside[gone] == 0 { have -= 1; if must.contains(gone) { needed -= 1 } }
                }
            }
            if have >= enough, needed == must.count { return true }
        }
        return false
    }

    /// A paragraph's sentences: each is looked for on its own.
    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
    }

    // MARK: - a card

    /// One part of a card looked for: a table's cell, or a section.
    struct Finding: Equatable {
        /// The row and column of a cell, or the section's number and 0.
        let row: Int, column: Int
        let verdict: Verdict
        /// For a section: how many of its sentences weren't found, of how many.
        var missing = 0, of = 0

        var words: String {
            guard of > 1, missing > 0, verdict == .notFound || verdict == .notInPartRead else { return verdict.words }
            return "\(missing) of \(of) sentences \(verdict.words)"
        }
    }

    /// Every part with something to look for, against the text its own
    /// source badge stands for.
    static func check(_ artifact: Artifact) -> [Finding] {
        var sources: [SourceSnapshots.Key: (tokens: [String], whole: Bool)] = [:]
        func finding(_ row: Int, _ column: Int, _ claims: [String], _ source: Artifact.Source?) -> Finding? {
            let parts = claims.map(tokens).filter(checkable)
            guard !parts.isEmpty else { return nil }
            guard let source else { return Finding(row: row, column: column, verdict: .noSource) }
            let key = SourceSnapshots.Key(tab: source.tab, page: source.page)
            if sources[key] == nil, let page = artifact.evidence[key] {
                let read = page.read
                sources[key] = (tokens(read.text), read.whole)
            }
            guard let text = sources[key] else { return Finding(row: row, column: column, verdict: .noText) }
            let missing = parts.filter { !matches($0, in: text.tokens) }.count
            let verdict: Verdict = missing == 0 ? .found : text.whole ? .notFound : .notInPartRead
            return Finding(row: row, column: column, verdict: verdict, missing: missing, of: parts.count)
        }
        if artifact.kind == .table {
            return artifact.rows.enumerated().flatMap { row, cells in
                cells.enumerated().compactMap { column, cell in finding(row, column, [cell.text], cell.source) }
            }
        }
        return artifact.sections.enumerated().compactMap { number, section in
            finding(number, 0, sentences(section.body.isEmpty ? section.heading : section.body), section.source)
        }
    }

    /// The line over a checked card.
    static func summary(_ findings: [Finding]) -> String {
        func count(_ match: (Verdict) -> Bool) -> Int { findings.filter { match($0.verdict) }.count }
        var parts = ["\(count { $0 == .found }) found",
                     "\(count { $0 == .notFound || $0 == .notInPartRead }) not found in the source"]
        let unkept = count { $0 == .noText }, unnamed = count { $0 == .noSource }
        if unkept > 0 { parts.append("\(unkept) with no source text kept") }
        if unnamed > 0 { parts.append("\(unnamed) with no source named") }
        if findings.isEmpty { parts = ["nothing here to look for"] }
        return "Text match only: " + parts.joined(separator: ", ")
            + ". A match doesn't make a claim right, and no match doesn't make it wrong."
    }
}
