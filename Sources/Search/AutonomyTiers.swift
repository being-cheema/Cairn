import Foundation

// How much an agent may do on one site on its own, as the person set it in
// the site card: Standard (the commit gates as they are), Trusted Hub, or
// Vaulted (closed to agents: VaultedSites).
//
// A Trusted Hub only drops one question, the one about leaving the task's
// sites by a link out of that site (AgentGate `leave`). Paying, sending,
// signing in, submitting and every other hold stay as they are, and so do
// the private-network, store and secret rules: nothing about an agent's reach
// changes, only how often it asks before going somewhere from a site you
// trust to link out. Only a click of the person's in the site card sets one.
// Vaulted outranks a hub: a site in both is closed.

enum AutonomyTier: String, CaseIterable, Hashable {
    case standard, trustedHub, vaulted

    var title: String {
        switch self {
        case .standard: "Standard"
        case .trustedHub: "Trusted Hub"
        case .vaulted: "Vaulted"
        }
    }
}

enum AutonomyTiers {
    static let key = "agents.trustedHubs"

    /// Read from the settings each time, as VaultedSites is.
    static var current: Set<String> { Set(Store.settings.stringArray(forKey: key) ?? []) }

    static func tier(of url: URL?, vaulted: Set<String>, hubs: Set<String>) -> AutonomyTier {
        if VaultedSites.blocks(url, in: vaulted) { return .vaulted }
        return VaultedSites.blocks(url, in: hubs) ? .trustedHub : .standard
    }

    /// Both lists after `tier` is chosen for the site of `url`: the site is
    /// in the one list that says it, and no entry covering it is left in the
    /// other.
    static func setting(_ tier: AutonomyTier, for url: URL, vaulted: Set<String>, hubs: Set<String>,
                        registrable: (String) -> String = Vault.registrable) -> (vaulted: Set<String>, hubs: Set<String>) {
        let closed = VaultedSites.setting(tier == .vaulted, for: url, in: vaulted, registrable: registrable)
        var hub = hubs
        if let host = VaultedSites.host(of: url) { hub = hub.filter { !VaultedSites.covers($0, host) } }
        if tier == .trustedHub, let entry = VaultedSites.entry(for: url, registrable: registrable) { hub.insert(entry) }
        return (closed, hub)
    }
}
