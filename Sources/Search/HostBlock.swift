import Foundation

// The one place that asks whether a host is off limits to what reads pages on
// its own: reading memory, before it keeps a page, and batch_read, before and
// after it opens one. The answer is your list of sites closed to agents
// (VaultedSites).

enum HostBlock {
    static func isBlocked(_ host: String) -> Bool {
        VaultedSites.current.contains { VaultedSites.covers($0, host) }
    }
}
