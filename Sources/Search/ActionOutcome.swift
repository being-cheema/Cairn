import Foundation

// What a click, a typing or a key did, as far as the page showed it, said to
// the agent with the action's answer so that a dead click is not mistaken for
// a done one.
//
// It only informs. Nothing here is asked before an action, and no gate
// (AgentGate), no refusal and no question changes with what was seen.
//
// What it can and can't see. Navigation is the tab's own address, or the page's
// own watch being gone with its document. A change in the page is a
// MutationObserver of Search's, in Search's world, for about 400 ms. The
// network is only what resource timing lists for the page's own fetch, XHR
// and beacons that had finished in that time: WebKit has no public view of a
// page's traffic, and the page's own fetch can't be wrapped from Search's
// world, so a request still in flight at the end, or one a script made in a
// frame, is missed. That one is said to be best effort wherever it is said.

enum ActionOutcome: String, Equatable {
    case navigated
    case domMutated = "dom_mutated"
    case networkSettled = "network_settled"
    case noEffect = "no_effect"

    /// How long after the action the page is watched.
    static let window: TimeInterval = 0.4

    struct Observation: Equatable {
        /// The tab's address is not what it was.
        var addressChanged = false
        /// The page's own watch was gone when asked: its document was replaced.
        var documentReplaced = false
        var mutations = 0
        var requests = 0

        init(addressChanged: Bool, documentReplaced: Bool, mutations: Int, requests: Int) {
            self.addressChanged = addressChanged
            self.documentReplaced = documentReplaced
            self.mutations = mutations
            self.requests = requests
        }

        /// From the page's answer, or none when it couldn't be asked: counts
        /// are numbers within a sane range or zero, whatever the page's
        /// script seems to say.
        init(page: [String: Any]?, addressChanged: Bool) {
            self.addressChanged = addressChanged
            documentReplaced = page?["gone"] as? Bool == true
            func count(_ key: String) -> Int {
                guard let number = page?[key] as? NSNumber, number.intValue > 0 else { return 0 }
                return min(number.intValue, 100_000)
            }
            mutations = count("mutations")
            requests = count("requests")
        }
    }

    /// Most telling first: a new document, then a change in this one, then
    /// requests alone, then nothing.
    static func decide(_ seen: Observation) -> ActionOutcome {
        if seen.addressChanged || seen.documentReplaced { return .navigated }
        if seen.mutations > 0 { return .domMutated }
        if seen.requests > 0 { return .networkSettled }
        return .noEffect
    }

    /// The fields an answer carries, with the limits said beside them.
    static func fields(_ seen: Observation) -> [String: Any] {
        let outcome = decide(seen)
        var note = "What the page showed in about 400 ms after the action; it informs and changes nothing that is asked or held."
        switch outcome {
        case .networkSettled:
            note += " network_settled is best effort: only the page's own fetch and XHR that finished in that time show, from resource timing."
        case .noEffect:
            note += " A request still in flight, or a change after that time, isn't seen: wait_for a result or read_page before calling it dead."
        case .navigated, .domMutated:
            break
        }
        return ["outcome": outcome.rawValue,
                "outcome_seen": ["mutations": seen.mutations, "requests": seen.requests],
                "outcome_note": note]
    }
}
