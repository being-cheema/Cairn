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
    enum Refused: Error, Equatable { case notWeb, privateAddress, blockedByPerson }

    /// The address an agent's `open` or `go` names.
    @MainActor
    static func destination(_ text: String, allowed: Set<String>? = nil, vaulted: Set<String>? = nil) -> Result<URL, Refused> {
        guard let url = AgentRules.webAddress(text) else { return .failure(.notWeb) }
        // A site you closed to agents is refused here, before any gate could
        // ask you about going there.
        if VaultedSites.blocks(url, in: vaulted ?? VaultedSites.current) { return .failure(.blockedByPerson) }
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
        /// A site you closed to agents (VaultedSites), or under one.
        case blockedByPerson
        /// This Mac or a private network, as written.
        case privateAddress
        /// A name to look up before it is let through.
        case lookUp(String)
        /// A host a test run lets through although it is private.
        case clear
    }

    @MainActor
    static func screen(_ url: URL, allowed: Set<String>? = nil, vaulted: Set<String>? = nil) -> Screen {
        // First, so a blob: of a blocked site's isn't waved through below.
        if VaultedSites.blocks(url, in: vaulted ?? VaultedSites.current) { return .blockedByPerson }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .notWeb }
        let allowed = allowed ?? PrivateNetwork.allowed
        guard !PrivateNetwork.refuses(url, allowed: allowed) else { return .privateAddress }
        let host = url.host(percentEncoded: false) ?? ""
        return allowed.contains(PrivateNetwork.normalised(host)) ? .clear : .lookUp(host)
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
