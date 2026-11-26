import Foundation

// Commit gates: what an agent may propose and only you may commit.
//
// Always on, for every agent: the browser holds an agent's action that would commit
// something (a form sent, a payment, a message posted, a sign-in submitted)
// and performs it only after a fresh click of yours on the question in the
// window (AgentControl, AgentApproval). The agent is told it is waiting and
// is given the result, or "declined", afterwards; it can't answer for you.
//
// This file is the deciding: pure, so it can be tested without a page. It
// goes by what the browser can see of the element (its role, its label, the
// form it is in and what the form holds), which makes it a strong guard and
// not a proof: a page can name a payment button "Go", and the form around it
// is the other half of the check (card fields), but not all of it. The turn
// of a page to another by itself, after a click, is also beyond it.

enum AgentGate {
    /// What a click or Return would reach, as the page's script describes it.
    struct Target: Equatable {
        var tag = ""
        var type = ""
        var role = ""
        /// The page's words for it: data, never an instruction.
        var label = ""
        /// A button or input that submits the form it is in.
        var submits = false
        var inForm = false
        var hasPassword = false
        var hasCard = false
        var method = ""
        var action = ""
        var href = ""
        /// Return in it would submit its form.
        var enter = false
        /// The question is about Return pressed in a field, not a button.
        var viaReturn = false

        init() {}

        init?(_ json: Any?) {
            guard let d = json as? [String: Any] else { return nil }
            tag = d["tag"] as? String ?? ""
            type = d["type"] as? String ?? ""
            role = d["role"] as? String ?? ""
            label = d["label"] as? String ?? ""
            submits = d["submits"] as? Bool ?? false
            inForm = d["inForm"] as? Bool ?? false
            hasPassword = d["pw"] as? Bool ?? false
            hasCard = d["card"] as? Bool ?? false
            method = d["method"] as? String ?? ""
            action = d["action"] as? String ?? ""
            href = d["href"] as? String ?? ""
            enter = d["enter"] as? Bool ?? false
        }

        /// What makes it this element and not another, to be the same one
        /// when it is pressed as when it was asked about.
        var fingerprint: String { [tag, type, role, label, action, href].joined(separator: "\u{1}") }

        /// It does something when pressed, rather than being a field.
        var pressable: Bool { role == "button" || submits || ["submit", "button", "image"].contains(type) }
    }

    enum Reason: String, Equatable {
        case pay, send, signIn, submit, leave
    }

    /// What is held, in the words the question and the agent are given.
    struct Hold: Equatable {
        let reason: Reason
        /// Said by the browser alone, with the page's words quoted as such.
        let summary: String
        /// The site it would go to, for a `leave`: remembered once allowed.
        var site: String?
        /// Of the element it was asked about (Target.fingerprint).
        var fingerprint = ""
    }

    struct Rules: Equatable {
        /// Submit, pay, send, sign-in.
        var commits = false
        /// A site that isn't one of the task's.
        var leaves = false
        /// What every agent runs under: no switch turns it off.
        static let standard = Rules(commits: true, leaves: true)
    }

    // MARK: - words

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static let payWords = #"\b(pay|payment|buy|purchase|check ?out|place (your |my )?order|complete (your |my )?(order|purchase)|confirm (your |my )?(order|purchase|payment)|order now|donate|subscribe)\b"#
    static let sendWords = #"\b(send|post|publish|reply|tweet|share|comment|submit|confirm|delete|transfer)\b"#
    static let signInWords = #"\b(sign ?in|log ?in|sign ?up|register|create (an |your )?account)\b"#

    /// A label as it may be quoted: one short printable line.
    static func quoted(_ label: String) -> String {
        let line = label.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let squashed = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return squashed.count > 50 ? String(squashed.prefix(50)) + "…" : squashed
    }

    static func site(_ url: URL?, registrable: (String) -> String = Vault.registrable) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return registrable(host)
    }

    // MARK: - deciding

    /// A click on `target`, on the page at `page`, in a task that has been
    /// to `sites`. Nil: nothing to ask.
    static func hold(click target: Target, on page: URL?, sites: Set<String>, rules: Rules,
                     registrable: (String) -> String = Vault.registrable) -> Hold? {
        let where_ = page?.host()?.lowercased() ?? "this page"
        let name = quoted(target.label)
        let pressed = target.viaReturn ? "Return in a form" : name.isEmpty ? "a button" : "“\(name)”"

        if rules.commits {
            func held(_ reason: Reason, _ text: String) -> Hold { Hold(reason: reason, summary: text, fingerprint: target.fingerprint) }
            if target.hasCard, target.submits || (target.pressable && matches(payWords, target.label)) {
                return held(.pay, "Pay: press \(pressed) on \(where_)")
            }
            if (target.pressable || target.role == "link"), matches(payWords, target.label) {
                return held(.pay, "Pay: press \(pressed) on \(where_)")
            }
            if target.submits, target.hasPassword {
                return held(.signIn, "Sign in: press \(pressed) on \(where_)")
            }
            if target.pressable, matches(signInWords, target.label) {
                return held(.signIn, "Sign in: press \(pressed) on \(where_)")
            }
            if target.pressable, matches(sendWords, target.label) {
                return held(.send, "Send or post: press \(pressed) on \(where_)")
            }
            // A form that only looks something up (GET, nothing secret) is a
            // search, not a commitment.
            if target.submits, !(target.method == "get" && !target.hasPassword && !target.hasCard) {
                return held(.submit, "Send a form: press \(pressed) on \(where_)")
            }
        }
        if rules.leaves, target.role == "link", !target.href.isEmpty, let url = URL(string: target.href),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let there = site(url, registrable: registrable), !sites.isEmpty, !sites.contains(there) {
            return Hold(reason: .leave, summary: "Leave this task's sites: go to \(url.host() ?? there)", site: there,
                        fingerprint: target.fingerprint)
        }
        return nil
    }

    /// Return pressed in the element the page has focused.
    static func hold(enter target: Target, on page: URL?, rules: Rules) -> Hold? {
        guard rules.commits, target.enter else { return nil }
        var asSubmit = target
        asSubmit.submits = true
        // The field's own label says nothing about what Return would send.
        asSubmit.label = ""
        asSubmit.viaReturn = true
        // Return in a search box is a search.
        return hold(click: asSubmit, on: page, sites: [], rules: Rules(commits: true, leaves: false))
    }

    /// A document on its way out with something in it: a form sent, however
    /// it was started (AgentControl.vet). Said with the host alone.
    static func hold(sending method: String, to url: URL) -> Hold? {
        guard !["GET", "HEAD", "OPTIONS"].contains(method.uppercased()) else { return nil }
        return Hold(reason: .submit, summary: "Send a form: this page is sending data to \(url.host()?.lowercased() ?? "a site")")
    }

    /// An address the agent would take a tab to.
    static func hold(address url: URL, sites: Set<String>, rules: Rules,
                     registrable: (String) -> String = Vault.registrable) -> Hold? {
        guard rules.leaves, !sites.isEmpty, let there = site(url, registrable: registrable), !sites.contains(there) else { return nil }
        return Hold(reason: .leave, summary: "Leave this task's sites: go to \(url.host() ?? there)", site: there)
    }
}
