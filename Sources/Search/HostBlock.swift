import Foundation

// The one place that asks whether a host is off limits to what reads pages on
// its own: reading memory, before it keeps a page, and batch_read, before and
// after it opens one. No host is, yet: "vaulted domains" is built elsewhere,
// and answers here.

enum HostBlock {
    static func isBlocked(_ host: String) -> Bool {
        false
    }
}
