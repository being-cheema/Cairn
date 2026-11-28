import CryptoKit
import Foundation

// What an agent is told about an action it took, in the browser's words:
// what changed, what moved, what the page asked for and kept, and, when the
// action did not do what it was for, a code to branch on with how to go on.
//
// Pure, so it can be tested without a page. The numbers come from two looks
// at the page (PageScripts.snapshot) around the action. The browser can see
// the document, its storage by key and the requests the page's own resource
// timing lists; it cannot see the network or every kind of storage, so
// nothing here claims to be complete, and says so beside what it lists.

// MARK: - why an action didn't do its work

/// A reason an action did not do what it was for. The first group the
/// browser knows for certain; the rest it guesses at from the page's words
/// and says so (`heuristic`). An agent never solves a CAPTCHA: the code says
/// to hand the tab to the person.
enum ActionFailure: String, CaseIterable {
    case noEffect = "NO_EFFECT", occluded = "OCCLUDED", detached = "DETACHED", disabled = "DISABLED"
    case validationBlocked = "VALIDATION_BLOCKED", navInterrupted = "NAV_INTERRUPTED"
    case authWall = "AUTH_WALL", captcha = "CAPTCHA", rateLimit = "RATE_LIMIT", paywall = "PAYWALL"
    case loopSuspected = "LOOP_SUSPECTED"
    /// The same action again on a page it left as it was: held for the person.
    case duplicate = "DUPLICATE_ACTION"

    /// A guess from the page's words, not something the browser knows.
    var heuristic: Bool {
        switch self {
        case .authWall, .captcha, .rateLimit, .paywall, .noEffect: true
        default: false
        }
    }

    var hint: String {
        switch self {
        case .noEffect: "Nothing the browser could see changed. Read the page again before trying anything else; the same action again will likely do the same."
        case .occluded: "Something is drawn over it. Close or move what covers it (see occluded_by in read_page), or scroll, then read the page again."
        case .detached: "The page has drawn that element again or removed it. Call read_page again, or name it by its eid."
        case .disabled: "It can't be used yet. Fill in what it needs first, then read the page again."
        case .validationBlocked: "The page's own check refused the form. The fields it names (eid and the browser's message) need other values."
        case .navInterrupted: "The page was still going somewhere when the wait ended. Use wait_for, then read the page."
        case .authWall: "The page wants an account. Open its sign-in page and call wait_for_sign_in: the person signs in themselves."
        case .captcha: "A check for robots. Don't try to pass it: hand the tab to the person with wait_for_sign_in, or tell them."
        case .rateLimit: "The site says to slow down. Wait, don't repeat the request quickly, and say so in your reply."
        case .paywall: "The rest is for subscribers. Say so in your reply; don't look for a way round it."
        case .loopSuspected: "Cairn stopped this run's actions because the trace repeats. Say what you were trying, and stop."
        case .duplicate: "The person is asked before the same thing is done twice. Don't repeat it unless they say to."
        }
    }

    /// The code for a refusal the page scripts or the browser already made.
    static func from(refusal code: String) -> ActionFailure? {
        switch code {
        case "obscured", "out_of_view", "not_visible": .occluded
        case "detached", "stale_element": .detached
        case "disabled": .disabled
        case "LOOP_SUSPECTED": .loopSuspected
        default: nil
        }
    }

    var said: [String: Any] {
        var out: [String: Any] = ["code": rawValue, "hint": hint]
        if heuristic { out["heuristic"] = "A guess from what the page shows, not something the browser knows." }
        return out
    }

    // MARK: walls

    /// A wall the page put up since `before`: sign-in, a check for robots, a
    /// limit, a paywall. A page that always looked like this isn't blamed on
    /// the action. All from the page's words and its widgets: guesses.
    static func wall(before: PageState, after: PageState) -> ActionFailure? {
        func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        let was = before.sample, now = after.sample
        func fresh(_ pattern: String) -> Bool { matches(pattern, now) && !matches(pattern, was) }
        if after.captcha && !before.captcha
            || fresh(#"verify (that )?you('| a)re (a )?(human|not a robot)|are you a robot|unusual traffic from your"#) { return .captcha }
        if fresh(#"too many requests|rate limit|you are being rate limited|slow down|error 429|try again (later|in a few)"#) { return .rateLimit }
        if fresh(#"subscribe to (continue|read|unlock)|(continue|keep) reading with a subscription|you('|’)ve reached your (free|monthly)|unlock this (article|story)|paywall"#) { return .paywall }
        let loginAddress = after.url != before.url && matches(#"/(log-?in|sign-?in|auth|sso)\b"#, after.url.lowercased())
        if (after.password && !before.password && fresh(#"sign in|log in|login|password"#)) || loginAddress { return .authWall }
        return nil
    }
}

// MARK: - the page, looked at

/// One look at a page (PageScripts.snapshot), as much as a receipt compares.
struct PageState: Equatable {
    struct Focus: Equatable { var eid: String, role: String, name: String }
    struct Request: Equatable { var via: String, origin: String, status: Int? }
    struct Target: Equatable {
        var eid: String, role: String, tag: String
        var secret = false, submits = false, inForm = false, disabled = false
        var form = ""
        var invalid: [[String: String]] = []
        var hitTestable = false, occludedBy: String?, why: String?
    }

    var url = "", hash = ""
    var nodes: [String: String] = [:]
    var textLength = 0
    var focus: Focus?
    var storage: [String: [String: String]] = [:]
    var requestTotal = 0, requestsFull = false
    var requests: [Request] = []
    /// The page's first words, lower case: only to be guessed from (walls),
    /// never given on.
    var sample = ""
    var captcha = false, password = false
    var target: Target?

    init() {}

    init?(_ json: [String: Any]) {
        guard let hash = json["hash"] as? String else { return nil }
        self.hash = hash
        url = json["url"] as? String ?? ""
        nodes = json["nodes"] as? [String: String] ?? [:]
        textLength = json["textLength"] as? Int ?? 0
        if let f = json["focus"] as? [String: Any], let eid = f["eid"] as? String {
            focus = Focus(eid: eid, role: f["role"] as? String ?? "", name: f["name"] as? String ?? "")
        }
        for (key, value) in json["storage"] as? [String: Any] ?? [:] {
            if let map = value as? [String: String] { storage[key] = map }
        }
        let r = json["requests"] as? [String: Any] ?? [:]
        requestTotal = r["total"] as? Int ?? 0
        requestsFull = r["full"] as? Bool ?? false
        requests = (r["recent"] as? [[String: Any]] ?? []).map {
            Request(via: $0["via"] as? String ?? "", origin: $0["origin"] as? String ?? "", status: $0["status"] as? Int)
        }
        sample = json["sample"] as? String ?? ""
        captcha = json["captcha"] as? Bool ?? false
        password = json["password"] as? Bool ?? false
        if let t = json["target"] as? [String: Any], let eid = t["eid"] as? String {
            var made = Target(eid: eid, role: t["role"] as? String ?? "", tag: t["tag"] as? String ?? "")
            made.secret = t["secret"] as? Bool ?? false
            made.submits = t["submits"] as? Bool ?? false
            made.inForm = t["inForm"] as? Bool ?? false
            made.disabled = t["disabled"] as? Bool ?? false
            made.form = t["form"] as? String ?? ""
            made.invalid = (t["invalid"] as? [[String: Any]] ?? []).map {
                ["eid": $0["eid"] as? String ?? "", "message": $0["message"] as? String ?? ""]
            }
            let hit = t["hit"] as? [String: Any] ?? [:]
            made.hitTestable = hit["testable"] as? Bool ?? false
            made.occludedBy = hit["by"] as? String
            made.why = hit["why"] as? String
            target = made
        }
    }
}

// MARK: - what changed

struct PageDelta: Equatable {
    var added = 0, removed = 0, changed = 0
    var moved = false
    var textChange = 0
    var focusMoved = false
    var storageChanges = 0
    var requests = 0
    /// Something in the page's words or controls differs, however small.
    var different = false

    init(from before: PageState, to after: PageState) {
        let was = Set(before.nodes.keys), now = Set(after.nodes.keys)
        added = now.subtracting(was).count
        removed = was.subtracting(now).count
        changed = now.intersection(was).filter { before.nodes[$0] != after.nodes[$0] }.count
        moved = before.url != after.url
        textChange = after.textLength - before.textLength
        focusMoved = before.focus?.eid != after.focus?.eid
        for key in Set(before.storage.keys).union(after.storage.keys) {
            let (a, b) = (before.storage[key] ?? [:], after.storage[key] ?? [:])
            storageChanges += Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.count
        }
        requests = max(0, after.requestTotal - before.requestTotal)
        different = before.hash != after.hash
    }

    /// Whether anything the browser can see is different.
    var none: Bool { added + removed + changed == 0 && !moved && textChange == 0 && !focusMoved && storageChanges == 0 && requests == 0 && !different }

    /// In the browser's words alone: counts, never what the page called anything.
    var summary: String {
        if none { return "Nothing the browser could see changed" }
        var parts: [String] = []
        if moved { parts.append("the address changed") }
        if added > 0 { parts.append("\(added) control\(added == 1 ? "" : "s") appeared") }
        if removed > 0 { parts.append("\(removed) went") }
        if changed > 0 { parts.append("\(changed) changed") }
        if textChange != 0 { parts.append("the page's text is \(abs(textChange)) characters \(textChange > 0 ? "longer" : "shorter")") }
        if focusMoved { parts.append("focus moved") }
        if parts.isEmpty && different { parts.append("the page's words or controls differ") }
        if storageChanges > 0 { parts.append("\(storageChanges) stored value\(storageChanges == 1 ? "" : "s") changed") }
        if requests > 0 { parts.append("\(requests) request\(requests == 1 ? "" : "s") seen") }
        let line = parts.joined(separator: "; ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}

// MARK: - the receipt

enum ActionReceipt {
    static let bestEffort = "Best effort, not a complete record: only the page's own fetch, XHR and beacon requests that its resource timing lists (their method is not visible, and often not their status), and only the storage the page's script can read, by key (not cookies marked httpOnly, IndexedDB or caches)."

    /// The receipt for an action, as it goes in the answer. `url` turns an
    /// address into the one an agent may be given (AgentRules.url);
    /// `label` marks the page's words.
    static func make(id: String, action: String, origin: String, before: PageState, after: PageState,
                     url: (String) -> String, label: (String) -> String) -> [String: Any] {
        let delta = PageDelta(from: before, to: after)
        var focus: [[String: String]] = []
        if before.focus?.eid != after.focus?.eid {
            focus = [["from_eid": before.focus?.eid ?? "", "from_role": before.focus?.role ?? "none",
                      "to_eid": after.focus?.eid ?? "", "to_role": after.focus?.role ?? "none",
                      "to_name": label(after.focus?.name ?? "")]]
        }
        let fresh = delta.requests
        let seen = after.requests.suffix(min(fresh, after.requests.count)).map { r -> [String: Any] in
            ["via": r.via, "origin": r.origin, "status": r.status.map { $0 as Any } ?? "unknown"]
        }
        // Only the parts that saw something: an empty list is tokens for
        // nothing. The page's hashes and the dedupe key stay in Cairn (the
        // ledger and the loop breaker use them); the model is not sent them.
        var effects: [String: Any] = [:]
        if !seen.isEmpty || delta.requests > 0 {
            var network: [String: Any] = ["requests": seen, "best_effort": bestEffort]
            if fresh > after.requests.count || after.requestsFull { network["incomplete"] = true }
            effects["network"] = network
        }
        if before.url != after.url { effects["navigations"] = [["from": url(before.url), "to": url(after.url)]] }
        if delta.storageChanges > 0 { effects["storage_writes"] = ["changed": delta.storageChanges, "best_effort": bestEffort] }
        if !focus.isEmpty { effects["focus_changes"] = focus }
        var out: [String: Any] = [
            "action_id": id, "action": action,
            "eid": after.target?.eid ?? before.target?.eid ?? "",
            "delta_summary": delta.summary,
        ]
        if !effects.isEmpty { out["side_effects"] = effects }
        if before.hash == after.hash { out["unchanged"] = true }
        return out
    }
}

// MARK: - the same thing twice

enum Dedupe {
    /// sha256(origin, action, target eid, form values hash), the first 16 hex.
    static func key(origin: String, action: String, eid: String, values: String) -> String {
        let text = [origin, action, eid, values].joined(separator: "\u{1}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// The hash of the values given to a fill, by eid, never the values.
    static func values(_ pairs: [(eid: String, value: String)]) -> String {
        let text = pairs.sorted { $0.eid < $1.eid }.map { "\($0.eid)=\($0.value)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// Whether the person is asked before this is done again on the same
    /// page: what can't be undone by doing it twice. A link is a place to go
    /// to and is let go; a field set to what it holds is the same either
    /// way; a plain key is not a commitment.
    static func guards(action: String, role: String, key: String = "", submit: Bool = false) -> Bool {
        switch action {
        case "click": return role != "link"
        case "type": return submit
        case "press": return key == "Enter" || key == " " || key == "Space"
        default: return false
        }
    }
}

/// What an action did, as far as a repeat of it goes: kept per task.
struct DedupeLedger {
    private struct Entry { var after: String; var at: TimeInterval; var effective: Bool }
    private var entries: [String: Entry] = [:]
    static let window: TimeInterval = 120

    /// Done once already, with an effect, and the page is where that left it.
    func isRepeat(_ key: String, pageNow hash: String, at now: TimeInterval) -> Bool {
        guard let entry = entries[key] else { return false }
        return entry.effective && entry.after == hash && now - entry.at <= Self.window
    }

    mutating func record(_ key: String, before: String, after: String, at now: TimeInterval) {
        entries[key] = Entry(after: after, at: now, effective: before != after)
        if entries.count > 200 { entries = entries.filter { now - $0.value.at <= Self.window } }
    }
}

/// What one task has done, for numbering its actions and noticing a repeat.
struct ActionBook {
    private(set) var count = 0
    var ledger = DedupeLedger()
    /// The run's hard limits (LoopBreaker), as set when it began.
    var breaker = LoopBreaker()

    mutating func next() -> String {
        count += 1
        return "act-\(count)"
    }
}


/// One step of a turn, as the panel's timeline shows it: what a receipt said,
/// in the browser's words. Kept in memory with the turn and nowhere else.
/// The seam for a checkpoint to rewind to (a page's interactionState) is
/// `id`: the receipt's action_id.
struct TrailStep: Identifiable, Equatable {
    let id: String
    let verb: String
    let summary: String
    let failure: String?
    let requests: Int, navigations: Int, storageChanges: Int
    let eid: String

    init?(receipt: [String: Any], failure: String?) {
        guard let id = receipt["action_id"] as? String else { return nil }
        self.id = id
        verb = receipt["action"] as? String ?? ""
        summary = receipt["delta_summary"] as? String ?? ""
        self.failure = failure
        let effects = receipt["side_effects"] as? [String: Any] ?? [:]
        requests = ((effects["network"] as? [String: Any])?["requests"] as? [Any])?.count ?? 0
        navigations = (effects["navigations"] as? [Any])?.count ?? 0
        storageChanges = (effects["storage_writes"] as? [String: Any])?["changed"] as? Int ?? 0
        eid = receipt["eid"] as? String ?? ""
    }

    /// The step in one line, for the list.
    var line: String { "\(verb): \(failure.map { $0 + ", " } ?? "")\(summary)" }

    /// What it did beyond the page, for the detail under the slider.
    var effects: String {
        var parts: [String] = []
        if navigations > 0 { parts.append("\(navigations) navigation\(navigations == 1 ? "" : "s")") }
        if requests > 0 { parts.append("\(requests) request\(requests == 1 ? "" : "s") seen") }
        if storageChanges > 0 { parts.append("\(storageChanges) stored value\(storageChanges == 1 ? "" : "s") changed") }
        return parts.isEmpty ? "Nothing beyond the page was seen (a best-effort view)" : parts.joined(separator: ", ") + " (a best-effort view)"
    }
}
