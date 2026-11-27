import Foundation

// Where an agent's words came from, as a second pair of eyes on a cross-site
// flow. A task keeps, in memory and until it ends, the text it read and the
// site each part came from (and whether the page's words were quarantined
// as looking like orders). Before it types into a page, or goes to an
// address, on a different site, what it is about to send is compared with
// that text; a substantial overlap is put to you as a question, naming the
// site the words came from.
//
// This is a HEURISTIC and it says so wherever it speaks: it matches runs of
// words and long identifiers, so a model that paraphrases, abbreviates or
// encodes what it read gets past it, and it can't see a page's own scripts.
// It only ever adds a question. It never approves, skips or loosens anything
// (AgentGate's other holds are decided before and apart from it), and a yes
// to it is remembered for nothing. Values of password, card and one-time-code
// fields are never recorded: a read doesn't contain them to begin with
// (PageScripts redacts them), and what a field was once seen to be stays so.

struct TaintLedger {
    struct Match: Equatable {
        /// The site the words were read on.
        let origin: String
        /// Its words had been marked as looking like orders (Quarantine).
        let quarantined: Bool
    }

    private struct Entry {
        let origin: String
        let quarantined: Bool
        let shingles: Set<Int>
        let identifiers: Set<String>
        let size: Int
    }

    /// Words in a run that counts as a copy. Shorter runs are phrases pages
    /// share ("terms of service and privacy policy").
    static let run = 6
    /// A run must also be this long and varied, so six small words don't count.
    static let shortest = 30
    /// The shortest single token taken as an identifier (an order number, a
    /// key): letters and digits both, so a long word is only a word.
    static let identifier = 12
    /// What is kept at most, in characters read: the oldest go first.
    static let limit = 600_000

    private var entries: [Entry] = []
    private(set) var characters = 0

    var isEmpty: Bool { entries.isEmpty }

    mutating func clear() {
        entries = []
        characters = 0
    }

    mutating func record(_ text: String, origin: String, quarantined: Bool) {
        let clipped = String(text.prefix(200_000))
        let words = Self.words(clipped)
        guard words.count >= 1 else { return }
        let entry = Entry(origin: origin, quarantined: quarantined, shingles: Self.shingles(words),
                          identifiers: Self.identifiers(words), size: clipped.count)
        entries.append(entry)
        characters += entry.size
        while characters > Self.limit, let first = entries.first {
            characters -= first.size
            entries.removeFirst()
        }
    }

    /// Where `outgoing` seems to have been read, on a site other than
    /// `origin`: the latest such, or nil.
    func source(of outgoing: String, into origin: String) -> Match? {
        let words = Self.words(outgoing)
        guard !words.isEmpty else { return nil }
        let shingles = Self.shingles(words)
        let identifiers = Self.identifiers(words)
        for entry in entries.reversed() where entry.origin != origin {
            if !shingles.isDisjoint(with: entry.shingles) || !identifiers.isDisjoint(with: entry.identifiers) {
                return Match(origin: entry.origin, quarantined: entry.quarantined)
            }
        }
        return nil
    }

    // MARK: - the matching

    /// Lower-cased runs of letters and digits: case, spacing and punctuation
    /// don't hide a copy.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    private static func shingles(_ words: [String]) -> Set<Int> {
        guard words.count >= run else { return [] }
        var out = Set<Int>()
        for start in 0...(words.count - run) {
            let slice = words[start..<(start + run)]
            guard Set(slice).count >= 4 else { continue }
            let joined = slice.joined(separator: " ")
            if joined.count >= shortest { out.insert(joined.hashValue) }
        }
        return out
    }

    private static func identifiers(_ words: [String]) -> Set<String> {
        Set(words.filter { word in
            word.count >= identifier && word.contains(where: \.isNumber) && word.contains(where: \.isLetter)
        })
    }

    // MARK: - sites and addresses

    /// The site a page is on, as the task's other sites are named
    /// (AgentGate.site), with the port when it isn't the usual one, so two
    /// local servers are two places.
    static func origin(of url: URL?, registrable: (String) -> String = Vault.registrable) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let site = AgentGate.site(url, registrable: registrable) else { return nil }
        if let port = url.port, port != 80, port != 443 { return "\(site):\(port)" }
        return site
    }

    /// What an address can carry out: its path, query values and fragment,
    /// decoded, with the host and the query's names left out.
    static func text(of url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        var pieces = [parts.path]
        pieces += (parts.queryItems ?? []).compactMap(\.value)
        if let fragment = parts.fragment { pieces.append(fragment) }
        return pieces.compactMap { $0.removingPercentEncoding ?? $0 }.joined(separator: " ")
    }
}

extension AgentGate {
    /// A question for an action whose words seem to have been read on another
    /// site. Said in the browser's words, the site's name its own; never
    /// remembered as a site (no `site`), so it is asked again next time.
    static func hold(flowFrom match: TaintLedger.Match, into host: String, doing verb: String) -> Hold {
        let where_ = host.isEmpty ? "another site" : host
        var warning = "This is a guess from matching words: it can miss data that was reworded and flag text that merely looks alike."
        if match.quarantined { warning = "That page's text had also been flagged as looking like instructions. " + warning }
        let said = verb == "go"
            ? "go to \(where_) with an address that seems to carry text from \(match.origin)"
            : "type text that seems to come from \(match.origin) into \(where_)"
        return Hold(reason: .flow, summary: "Send data between sites: \(said)", warning: warning)
    }
}
