import Foundation

// A task's budget of page words. Once what it has been read passes the
// budget, a read of a tab it has left (not the one it last acted in) comes
// back as an outline: its headings, a few controls and the start of its
// text, with how much was left out. The tab it works in stays whole, and so
// does any read while the budget lasts.
//
// What it is not. It shortens what Cairn hands over from now on; it can't
// take back what the agent already holds. It never drops a mark: a control
// that was redacted keeps its mark, and the text is fenced afterwards as any
// read's is (Quarantine). Nothing is kept: the count lives in memory with the
// task.

struct ContextGovernor {
    static let budgetKey = "agents.contextBudget"
    static let defaultBudget = 120_000
    static let outlineNodes = 40
    static let outlineText = 1200

    let budget: Int
    private(set) var spent = 0

    /// The task's budget: the setting, in characters, or the default.
    init(budget: Int? = nil) {
        let set = Store.settings.integer(forKey: Self.budgetKey)
        self.budget = budget ?? (set > 0 ? set : Self.defaultBudget)
    }

    mutating func spend(_ characters: Int) { spent += max(characters, 0) }

    /// Whether this read is the short kind.
    func compacts(active: Bool) -> Bool { !active && spent >= budget }

    /// How much a read weighs: its words and what it names.
    static func weight(_ out: [String: Any]) -> Int {
        let nodes = out["nodes"] as? [[String: Any]] ?? []
        return ((out["text"] as? String)?.count ?? 0) + nodes.reduce(0) { $0 + 60 + (($1["name"] as? String)?.count ?? 0) }
    }

    /// The read as an outline. Every heading, dialog and alert is kept first,
    /// then controls in the page's order up to the limit; a redacted
    /// control is kept as it was, mark and all.
    static func compact(_ out: [String: Any]) -> [String: Any] {
        var out = out
        let nodes = out["nodes"] as? [[String: Any]] ?? []
        let first: Set<String> = ["heading", "dialog", "alertdialog", "alert"]
        var kept = nodes.filter { first.contains($0["role"] as? String ?? "") }.prefix(outlineNodes)
        let room = outlineNodes - kept.count
        let others = nodes.filter { !first.contains($0["role"] as? String ?? "") }
        let marked = others.filter { $0["redacted"] as? Bool == true }
        kept.append(contentsOf: marked)
        kept.append(contentsOf: others.filter { $0["redacted"] as? Bool != true }.prefix(max(room, 0)))
        let keptSet = kept.map { $0["element"] as? String ?? "\($0["name"] ?? "")" }
        out["nodes"] = nodes.filter { node in keptSet.contains(node["element"] as? String ?? "\(node["name"] ?? "")") }
        var textChars = 0
        if let text = out["text"] as? String {
            out["text"] = String(text.prefix(outlineText))
            textChars = text.count
            out["textTruncated"] = text.count > outlineText
            out["nextTextOffset"] = nil
        }
        out["nodesTruncated"] = true
        out["compacted"] = ["nodesOf": nodes.count, "nodesKept": (out["nodes"] as? [Any])?.count ?? 0, "textChars": textChars,
                            "hint": "This tab isn't the one you are working in, and this task has read a lot: this is an outline. "
                                + "Act in the tab (scroll it to top, say) and read it again for the whole page."] as [String: Any]
        return out
    }
}
