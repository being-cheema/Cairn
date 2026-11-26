import Foundation

// What changed on a page between two of an agent's reads, and when a page is
// still enough to be read or clicked.
//
// Pure, so both can be tested without a page. The script half keeps an
// element's place in the list from one read to the next within a document
// (PageScripts.read, `since`), so the same number is the same element and a
// difference is a difference of that element. Everything compared here has
// already been through the page script's redaction: a secret field has no
// value to compare, and an old value is never repeated in a difference.

/// Waiting for a page to hold still: no changes to its document and no
/// control moving, across two animation frames. A page that never stops (a
/// carousel, a ticker, a spinner) is given up on after `longest`.
struct PageSettle {
    struct Sample: Equatable {
        var mutations = 0
        /// Animation frames drawn since the watch began.
        var frames = 0
        /// Where the controls are, hashed in the page.
        var boxes = ""

        init(mutations: Int, frames: Int, boxes: String) {
            self.mutations = mutations
            self.frames = frames
            self.boxes = boxes
        }

        init?(_ json: [String: Any]) {
            guard let mutations = json["mutations"] as? Int, let frames = json["frames"] as? Int,
                  let boxes = json["boxes"] as? String else { return nil }
            self.init(mutations: mutations, frames: frames, boxes: boxes)
        }
    }

    enum Verdict: Equatable { case wait, settled, gaveUp }

    /// The hard bound: no verb waits on a page longer than this to hold still.
    static let longest: TimeInterval = 1.5
    static let interval: TimeInterval = 0.05
    /// A page that isn't being painted draws no frames (a tab off every
    /// screen can be one): quiet this long counts as still.
    static let quietWithoutFrames: TimeInterval = 0.3

    /// The first sample of the quiet stretch in hand, and when it was.
    private var since: (sample: Sample, at: TimeInterval)?

    mutating func take(_ sample: Sample, at elapsed: TimeInterval) -> Verdict {
        if let since, since.sample.mutations == sample.mutations, since.sample.boxes == sample.boxes {
            if sample.frames - since.sample.frames >= 2 { return .settled }
            if elapsed - since.at >= Self.quietWithoutFrames { return .settled }
        } else {
            since = (sample, elapsed)
        }
        return elapsed >= Self.longest ? .gaveUp : .wait
    }
}

/// One read of a page, kept to compare the next with.
struct PageSnapshot: Equatable {
    /// What was asked for: two reads of different windows of a page can't be
    /// compared.
    struct Asked: Equatable {
        var most = 0
        var longest = 0
        var nodeOffset = 0
        var textOffset = 0
        var viewportOnly = false
        var text = true
    }

    struct Node: Equatable {
        let index: Int
        let role: String
        let name: String
        /// Everything about it that counts as a change. Where it is doesn't:
        /// scrolling would change every node.
        let facts: [String: String]
    }

    var asked: Asked
    var snap: Int
    var url: String
    var title: String
    var nodes: [Node]
    var text: String
    var truncated: Bool

    static let compared = ["role", "name", "level", "value", "redacted", "filled", "checked", "expanded",
                           "selected", "pressed", "disabled", "readonly", "href"]

    /// From the page script's answer, before handles are put on its nodes.
    init(_ out: [String: Any], asked: Asked, snap: Int) {
        self.asked = asked
        self.snap = snap
        url = out["url"] as? String ?? ""
        title = out["title"] as? String ?? ""
        text = out["text"] as? String ?? ""
        truncated = out["nodesTruncated"] as? Bool ?? false
        nodes = (out["nodes"] as? [[String: Any]] ?? []).compactMap { node in
            guard let index = node["e"] as? Int else { return nil }
            var facts: [String: String] = [:]
            for key in Self.compared { if let value = node[key] { facts[key] = String(describing: value) } }
            return Node(index: index, role: node["role"] as? String ?? "", name: node["name"] as? String ?? "", facts: facts)
        }
    }
}

struct PageDiff: Equatable {
    struct Change: Equatable {
        let index: Int
        /// The names of what changed; never what it was before.
        let keys: [String]
    }

    var added: [Int] = []
    var removed: [PageSnapshot.Node] = []
    var changed: [Change] = []
    var linesAdded: [String] = []
    var linesRemoved: [String] = []
    /// Lines past the limits above.
    var linesCut = false
    var moved = false
    var retitled = false

    static let mostLines = 60
    static let mostCharacters = 4000

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && linesAdded.isEmpty && linesRemoved.isEmpty && !moved && !retitled
    }

    /// Why two reads can't be compared, or nil when they can. A read cut
    /// short would call whatever fell past the cut removed.
    static func unavailable(from old: PageSnapshot, to new: PageSnapshot, sameDocument: Bool) -> String? {
        if !sameDocument { return "a new document since the last read" }
        if old.asked != new.asked { return "the last read asked for something else" }
        if old.truncated || new.truncated { return "the list of controls was cut short" }
        return nil
    }

    static func between(_ old: PageSnapshot, _ new: PageSnapshot) -> PageDiff {
        var diff = PageDiff()
        let before = Dictionary(old.nodes.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Set(new.nodes.map(\.index))
        for node in new.nodes {
            guard let was = before[node.index] else { diff.added.append(node.index); continue }
            let keys = PageSnapshot.compared.filter { was.facts[$0] != node.facts[$0] }
            if !keys.isEmpty { diff.changed.append(Change(index: node.index, keys: keys)) }
        }
        diff.removed = old.nodes.filter { !now.contains($0.index) }
        (diff.linesAdded, diff.linesRemoved, diff.linesCut) = lines(old.text, new.text)
        diff.moved = old.url != new.url
        diff.retitled = old.title != new.title
        return diff
    }

    /// The lines that are new and the lines that are gone, counting repeats.
    private static func lines(_ old: String, _ new: String) -> ([String], [String], Bool) {
        func split(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var cut = false
        func only(_ these: [String], notIn those: [String]) -> [String] {
            var left = those.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            var out: [String] = []
            var length = 0
            for line in these {
                if let count = left[line], count > 0 { left[line] = count - 1; continue }
                guard out.count < mostLines, length < mostCharacters else { cut = true; break }
                let kept = String(line.prefix(mostCharacters - length))
                if kept != line { cut = true }
                length += kept.count
                out.append(kept)
            }
            return out
        }
        let (a, b) = (split(old), split(new))
        let added = only(b, notIn: a)
        let removed = only(a, notIn: b)
        return (added, removed, cut)
    }

    /// One line for the person, in the browser's words, with at most one of
    /// the page's quoted and cut short.
    func summary(of new: PageSnapshot) -> String {
        guard !isEmpty else { return "Nothing on the page changed" }
        var parts: [String] = []
        if moved, let host = URL(string: new.url)?.host() { parts.append("a new address on \(host)") }
        if !added.isEmpty { parts.append("\(added.count) new") }
        if !removed.isEmpty { parts.append("\(removed.count) gone") }
        if !changed.isEmpty { parts.append("\(changed.count) changed") }
        if added.isEmpty && removed.isEmpty && changed.isEmpty && !(linesAdded.isEmpty && linesRemoved.isEmpty) {
            parts.append("text changed")
        }
        if retitled && parts.isEmpty { parts.append("a new title") }
        // An alert or a dialog says more than a count; then a heading.
        let fresh = Set(added)
        let candidates = new.nodes.filter { fresh.contains($0.index) && !$0.name.isEmpty }
        let notable = candidates.first { ["alert", "alertdialog", "dialog"].contains($0.role) }
            ?? candidates.first { $0.role == "heading" }
        var out = "Page changed: " + parts.joined(separator: ", ")
        if let notable { out += "; now showing “\(AgentGate.quoted(TypedSecrets.hidden(in: notable.name)))”" }
        return out
    }
}
