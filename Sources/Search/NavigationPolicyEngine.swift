import Foundation

// What a tab an agent has may load, decided in one place.
//
// Pure: each answer comes from what is passed in, so it is tested without a
// page (NavigationPolicyTests). The waiting, the lookup and the question to
// the person are AgentControl.vet's; WebKit asks through Browser's
// navigation delegate. The other rules about where an agent goes are asked
// before it gets this far: the site change of `open` and `go` and of a link
// it clicks (AgentGate). HTTPS-first is yours as much as an agent's, and is
// applied with every page's preferences (HTTPSFirst).

enum NavigationPolicyEngine {
    /// Why `open` or `go` can't have an address.
    enum Refused: Error, Equatable { case notWeb, privateAddress }

    /// The address an agent's `open` or `go` names.
    @MainActor
    static func destination(_ text: String, allowed: Set<String>? = nil) -> Result<URL, Refused> {
        guard let url = AgentRules.webAddress(text) else { return .failure(.notWeb) }
        return PrivateNetwork.refuses(url, allowed: allowed) ? .failure(.privateAddress) : .success(url)
    }

    /// Whether a document is one an agent's tab never has, whoever asked:
    /// a download, or a scheme that is Cairn's own, a file or another app's.
    @MainActor
    static func neverLoads(_ url: URL?, download: Bool) -> Bool {
        download || !(url.map(AgentRules.mayLoad) ?? true)
    }

    /// What is known of a document from its address alone.
    enum Screen: Equatable {
        /// Not fetched from anywhere (about:, data:, blob:): nothing to ask.
        case notWeb
        /// This Mac or a private network, as written.
        case privateAddress
        /// A name to look up before it is let through.
        case lookUp(String)
        /// A host a test run lets through although it is private.
        case clear
    }

    @MainActor
    static func screen(_ url: URL, allowed: Set<String>? = nil) -> Screen {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .notWeb }
        let allowed = allowed ?? PrivateNetwork.allowed
        guard !PrivateNetwork.refuses(url, allowed: allowed) else { return .privateAddress }
        let host = url.host(percentEncoded: false) ?? ""
        return allowed.contains(PrivateNetwork.normalised(host)) ? .clear : .lookUp(host)
    }

    // MARK: data riding out in an address

    /// More than this after the path is more than a link usually needs.
    static let longAddressData = 200

    /// Why an address looks as if it may be carrying data out, in the
    /// browser's words, or nil. A guess, for a line on a question that is
    /// asked anyway: it never decides whether one is asked. Sites' own
    /// tracking addresses can look like this, and data cut into short or
    /// worded pieces doesn't.
    static func egressWarning(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let carried = (parts.percentEncodedQuery?.count ?? 0) + (parts.percentEncodedFragment?.count ?? 0)
        if carried > longAddressData {
            return "This address carries \(carried) characters of data after its path. It could be taking what the task has read to that site."
        }
        var values = (parts.queryItems ?? []).map { $0.value ?? $0.name }
        values += (parts.fragment ?? "").split(whereSeparator: { "&=/".contains($0) }).map(String.init)
        values += parts.path.split(separator: "/").map(String.init)
        let hidden = values.contains { looksEncoded($0) }
            || (parts.host ?? "").split(separator: ".").contains { looksEncodedLabel(String($0)) }
        return hidden ? "Part of this address looks like encoded data. It could be taking what the task has read to that site." : nil
    }

    /// A long run of hex, or of base64 that is mixed enough not to be words.
    static func looksEncoded(_ text: String) -> Bool {
        guard text.count >= 40 else { return false }
        if text.allSatisfy(\.isHexDigit) { return true }
        var body = Substring(text)
        while body.last == "=" { body = body.dropLast() }
        guard body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/_-".contains($0)) }),
              body.contains(where: \.isUppercase), body.contains(where: \.isLowercase), body.contains(where: \.isNumber)
        else { return false }
        return entropy(String(body)) >= 4.2
    }

    /// A name's label can't hold capitals that survive, so base32 and hex are
    /// what would ride in one.
    private static func looksEncodedLabel(_ label: String) -> Bool {
        guard label.count >= 32, !label.contains("-") else { return false }
        if label.allSatisfy(\.isHexDigit) { return true }
        return label.contains(where: \.isNumber) && entropy(label) >= 4.0
    }

    /// Bits a character, by how often each appears (Shannon).
    static func entropy(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let share = Double(count) / total
            return sum - share * log2(share)
        }
    }

    /// What happens to a document that carries something with it.
    enum Send: Equatable {
        /// Nothing to hold: a plain fetch, or a frame's own business.
        case go
        /// Your Approve just covered it; that Approve is now spent.
        case covered
        case ask(AgentGate.Hold)
    }

    /// A form on its way out. A frame's own posts (an advert's, a widget's)
    /// are its own affair, since the agent reads and touches no frame; one
    /// the page itself sends, or one that takes over the tab, is not.
    static func send(method: String, to url: URL, fromMainFrame: Bool, toMainFrame: Bool,
                     now: TimeInterval, grantedUntil: TimeInterval) -> Send {
        guard fromMainFrame || toMainFrame, let hold = AgentGate.hold(sending: method, to: url) else { return .go }
        return now < grantedUntil ? .covered : .ask(hold)
    }
}
