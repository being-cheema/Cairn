import Foundation

// Where an agent's words came from, as a second pair of eyes on a cross-site
// flow. A task keeps, in memory and until it ends, the text it read and the
// site each part came from (and whether the page's words were quarantined
// as looking like orders). Before it types into a page, or goes to an
// address, on a different site, what it is about to send is compared with
// that text; a substantial overlap is put to you as a question, naming the
// site the words came from.
//
// What counts is tuned to leave ordinary research alone. A passage of twelve
// words or more read elsewhere is asked about wherever it goes. A long
// identifier (an order number, a key) is too, unless it goes into a search
// field or a search engine's address, which is where model numbers belong.
// Text a page's own words had flagged as instructions (quarantined) is asked
// about at a six-word run, anywhere off its site. A link's address, and the
// words of a link's or page's title, as read, are not a flow by themselves:
// following what a page offered is what reading it was for.
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
        /// Six-word runs: a copy only of quarantined text.
        let shingles: Set<Int>
        /// Twelve-word runs: a copy of anything.
        let passages: Set<Int>
        let identifiers: Set<String>
        let size: Int
    }

    /// Words in a run that counts as a copy. Shorter runs are phrases pages
    /// share ("terms of service and privacy policy").
    static let run = 6
    /// Words in a run that counts as a passage, for text not flagged.
    static let passage = 12
    /// The longest title taken as a title: a longer one is a passage.
    static let longestTitle = 30
    /// A run must also be this long and varied, so six small words don't count.
    static let shortest = 30
    /// The shortest single token taken as an identifier (an order number, a
    /// key): letters and digits both, so a long word is only a word.
    static let identifier = 12
    /// What is kept at most, in characters read: the oldest go first.
    static let limit = 600_000

    private var entries: [Entry] = []
    /// Titles of pages and links as read (their words, joined), and the
    /// addresses links went to, per site. Never from quarantined text.
    private var titles = Set<String>()
    private var links: [String: Set<String>] = [:]
    private(set) var characters = 0

    var isEmpty: Bool { entries.isEmpty }

    mutating func clear() {
        entries = []
        titles = []
        links = [:]
        characters = 0
    }

    /// The titles and link addresses a read showed, for what is not a flow.
    mutating func record(titles seen: [String], links hrefs: [String], origin: String, quarantined: Bool) {
        guard !quarantined else { return }
        for title in seen {
            let words = Self.words(title)
            if !words.isEmpty, words.count <= Self.longestTitle { titles.insert(words.joined(separator: " ")) }
        }
        for href in hrefs {
            if let key = Self.key(of: href) { links[origin, default: []].insert(key) }
        }
        if links.count > 200 { links.removeValue(forKey: links.keys.first ?? "") }
    }

    /// An address one of the read pages' links went to, fragment aside.
    func isSeenLink(_ url: URL) -> Bool {
        guard let key = Self.key(of: url.absoluteString) else { return false }
        return links.values.contains { set in
            set.contains(key) || set.contains { $0.count >= 300 && key.hasPrefix($0) }
        }
    }

    /// An address without its fragment, its scheme and host in lower case.
    private static func key(of address: String) -> String? {
        guard var parts = URLComponents(string: address), parts.host != nil else { return nil }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        return parts.string
    }

    mutating func record(_ text: String, origin: String, quarantined: Bool) {
        let clipped = String(text.prefix(200_000))
        let words = Self.words(clipped)
        guard words.count >= 1 else { return }
        let entry = Entry(origin: origin, quarantined: quarantined, shingles: Self.shingles(words, run: Self.run),
                          passages: Self.shingles(words, run: Self.passage),
                          identifiers: Self.identifiers(words), size: clipped.count)
        entries.append(entry)
        characters += entry.size
        while characters > Self.limit, let first = entries.first {
            characters -= first.size
            entries.removeFirst()
        }
    }

    /// Where `outgoing` seems to have been read, on a site other than
    /// `origin`: the latest such, or nil. `searching` is a search field or a
    /// search engine's address, which identifiers may go into unasked.
    func source(of outgoing: String, into origin: String, searching: Bool = false) -> Match? {
        let words = Self.words(outgoing)
        guard !words.isEmpty, !titles.contains(words.joined(separator: " ")) else { return nil }
        let runs = Self.shingles(words, run: Self.run)
        let passages = Self.shingles(words, run: Self.passage)
        let identifiers = searching ? [] : Self.identifiers(words)
        for entry in entries.reversed() where entry.origin != origin {
            let copied = entry.quarantined ? !runs.isDisjoint(with: entry.shingles) : !passages.isDisjoint(with: entry.passages)
            if copied || !identifiers.isDisjoint(with: entry.identifiers) {
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

    private static func shingles(_ words: [String], run: Int) -> Set<Int> {
        guard words.count >= run else { return [] }
        var out = Set<Int>()
        for start in 0...(words.count - run) {
            let slice = words[start..<(start + run)]
            guard Set(slice).count >= run * 2 / 3 else { continue }
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

    /// A search engine's own address, or a site's search page: where a model
    /// number is what you type. Known engines by name; elsewhere only a path
    /// that says so.
    static func isSearch(_ url: URL, registrable: (String) -> String = Vault.registrable) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let engines: Set<String> = ["google.com", "bing.com", "duckduckgo.com", "search.brave.com", "brave.com",
                                    "ecosia.org", "startpage.com", "yahoo.com", "kagi.com", "qwant.com", "baidu.com",
                                    "yandex.com", "wikipedia.org"]
        if engines.contains(host) || engines.contains(registrable(host)) { return true }
        return url.path.lowercased().split(separator: "/").contains("search")
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

extension AgentGate.Target {
    /// A field made for searching: its role or type, or a form whose address
    /// says so. A heuristic too: a page can call any field a search.
    var isSearch: Bool {
        role == "searchbox" || type.lowercased() == "search" || (inForm && action.lowercased().contains("search"))
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
