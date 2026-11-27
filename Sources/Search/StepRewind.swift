import AppKit

// Rewind Step: before each action of an agent's that you approved, the panel
// keeps the page's back-forward state and place (WKWebView.interactionState),
// and one press of yours on the panel's button puts that tab back there.
//
// It restores the page only. It can't unsend a form, undo a purchase, take
// back a message or reverse anything a site did with what was sent: the
// button and its help say so. It is in memory, for the panel's current
// conversation; a new message or a new chat forgets it. Pressing it is
// yours alone (AgentRules.isClick); nothing an agent sends reaches it.

struct StepCheckpoint: Identifiable {
    let id = UUID()
    let tab: Tab.ID
    /// WebKit's opaque state, as Tab.keepsake gives it.
    let state: Any
    /// What was about to be done, in the browser's words (AgentGate.Hold.summary).
    let what: String
}

struct StepLog {
    static let most = 10
    private(set) var items: [StepCheckpoint] = []

    var last: StepCheckpoint? { items.last }

    mutating func keep(_ checkpoint: StepCheckpoint) {
        items.append(checkpoint)
        if items.count > Self.most { items.removeFirst(items.count - Self.most) }
    }

    /// The latest, taken off the list.
    mutating func pop() -> StepCheckpoint? { items.popLast() }

    mutating func clear() { items = [] }
}

extension ClaudeSession {
    var canRewind: Bool { !running && steps.last != nil }

    static let rewindWarning = "Puts the page back as it was before the last step you approved. It restores the page only: "
        + "it can't unsend a form, undo a payment or take back anything already sent."
}
