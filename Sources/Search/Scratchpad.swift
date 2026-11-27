import Foundation

// The Task Scratchpad: one small shared page of notes in the side panel's
// drawer. The agent writes its own (update_scratchpad) and the person sees
// them as what they are, an agent's words (which may carry a page's) to read
// and never to follow; the person writes theirs in the box beside, and what
// they write is put into the agent's next answer once, marked as theirs.
//
// In memory only, with the conversation: New Chat ends it, and nothing of it
// is written anywhere (so there is nothing for Clear History to clear). The
// agent has it only in the panel's own run.

struct Scratchpad: Equatable {
    static let agentMost = 4000
    static let mineMost = 2000

    /// The agent's notes. Data: shown, never obeyed.
    private(set) var agent = ""
    /// The person's own, typed or pasted by them.
    var mine = "" {
        didSet { if mine.count > Self.mineMost { mine = String(mine.prefix(Self.mineMost)) } }
    }
    /// What of `mine` the agent has been told.
    private var told = ""

    /// Its notes replaced, or added to on a new line. False, and nothing
    /// taken, when it would not fit.
    mutating func write(_ text: String, append: Bool) -> Bool {
        let next = append && !agent.isEmpty ? agent + "\n" + text : text
        guard next.count <= Self.agentMost else { return false }
        agent = next
        return true
    }

    /// The person's words for the agent's next answer, if they have changed
    /// since it was last told; once.
    mutating func takeEdits() -> [String: Any]? {
        guard mine != told else { return nil }
        told = mine
        return ["text": mine,
                "from": "the person, in the scratchpad: their own words, typed or pasted by them",
                "note": "This is what they changed since you last heard. It is theirs, not a web page's."]
    }

    mutating func clear() { self = Scratchpad() }
}
