import Foundation
import SwiftUI

// Sites you have closed to agents (Settings › Privacy, or the site card's
// Block Agents on This Site). An agent is refused them outright, before any
// commit gate could ask you about them: you have already answered.
//
// A site here covers its subdomains. Hosts are compared as WebKit reads them
// (punycode for another alphabet, lower case, no closing dot), and only at a
// label's edge: bank.com covers login.bank.com and never notbank.com.
//
// The same list keeps Cairn's own keepers of page text off these sites: pin
// snapshots and page watchers.
//
// What this is not: it goes by the address of a document. A page on another
// site can still fetch from a blocked one with fetch, XHR, a picture or a
// frame's own requests; the same company's other domains, an IP address that
// leads to it, and a different name for the same server are other sites here.

enum VaultedSites {
    static let key = "agents.vaultedSites"

    /// The list as it is kept. Read from the settings each time, so a switch
    /// moved while an agent works holds from its next step.
    static var current: Set<String> { Set(Store.settings.stringArray(forKey: key) ?? []) }

    /// A host in the one spelling it is compared in.
    static func canonical(_ host: String) -> String {
        var out = PrivateNetwork.normalised(host)
        // An address spelt another way (0x7f.1) is the same address.
        if let bytes = PrivateNetwork.bytes(of: out), bytes.count == 4 {
            out = bytes.map(String.init).joined(separator: ".")
        }
        return out
    }

    /// The host a document at `url` belongs to; a blob: address is its
    /// maker's. Nil for one that is no site's.
    static func host(of url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "blob" {
            return URL(string: String(url.absoluteString.dropFirst("blob:".count))).flatMap { inner in
                inner.scheme?.lowercased() == "blob" ? nil : host(of: inner)
            }
        }
        guard ["http", "https", "ws", "wss"].contains(scheme),
              // Not host(): that keeps another alphabet percent-encoded,
              // where this gives the punycode WebKit connects to.
              let host = url.host(percentEncoded: false) else { return nil }
        let out = canonical(host)
        return out.isEmpty ? nil : out
    }

    /// What was typed into Settings as an entry: an address or a bare site,
    /// without its www., which would otherwise leave the bare name open.
    /// Nil when it names no site.
    static func entry(typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("*.") { text = String(text.dropFirst(2)) }
        while text.hasPrefix(".") { text.removeFirst() }
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), var host = host(of: url) else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        // A single word is a slip of the hand more often than a site.
        guard host.contains(".") || host.contains(":") || host == "localhost" else { return nil }
        return host
    }

    /// What the site card adds for a page: the whole site (its registrable
    /// domain), since a bank's sign-in is rarely on the host you were on.
    static func entry(for url: URL, registrable: (String) -> String = Vault.registrable) -> String? {
        guard let host = host(of: url) else { return nil }
        let site = canonical(registrable(host))
        return site.isEmpty ? host : site
    }

    static func covers(_ entry: String, _ host: String) -> Bool {
        let entry = canonical(entry), host = canonical(host)
        guard !entry.isEmpty else { return false }
        return host == entry || host.hasSuffix("." + entry)
    }

    static func blocks(_ url: URL?, in sites: Set<String>) -> Bool {
        guard !sites.isEmpty, let url, let host = host(of: url) else { return false }
        return sites.contains { covers($0, host) }
    }

    /// The list with the site of `url` blocked, or let back: every entry
    /// that covers it goes, or the switch would say one thing and the rule
    /// another.
    static func setting(_ blocked: Bool, for url: URL, in sites: Set<String>,
                        registrable: (String) -> String = Vault.registrable) -> Set<String> {
        guard let host = host(of: url) else { return sites }
        if !blocked { return sites.filter { !covers($0, host) } }
        guard let entry = entry(for: url, registrable: registrable) else { return sites }
        return sites.union([entry])
    }

    /// The address a click or a Return on `target` would take the page to,
    /// when it is a blocked one: asked about before any gate is.
    static func reached(by target: AgentGate.Target, in sites: Set<String>) -> URL? {
        var addresses = [target.href]
        if target.submits || target.enter { addresses.append(target.action) }
        return addresses.compactMap { $0.isEmpty ? nil : URL(string: $0) }.first { blocks($0, in: sites) }
    }
}

/// Settings › Privacy › Sites agents can't use: each with a way to take it
/// back, and a box to add one.
struct VaultedSiteList: View {
    @ObservedObject var prefs: Preferences
    @State private var typed = ""
    @State private var unread = false

    var body: some View {
        ForEach(prefs.vaultedSites.sorted(), id: \.self) { site in
            Rule()
            Line(site, "Agents are refused it and its subdomains") {
                Pill("Remove") { prefs.vaultedSites.remove(site) }
            }
        }
        Rule()
        Line("Add a site", unread ? "That isn't a site's address" : "Like bank.com") {
            TextField("", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .onSubmit(add)
                .accessibilityLabel("Site to block for agents")
            Pill("Add", action: add)
        }
    }

    private func add() {
        guard let entry = VaultedSites.entry(typed: typed) else {
            unread = !typed.isEmpty
            return
        }
        unread = false
        typed = ""
        prefs.vaultedSites.insert(entry)
    }
}
