import Foundation
import WebKit

// Where an agent may not go: this Mac and the networks around it.
//
// An agent reads pages, and a page can ask it to open the router, a printer,
// a database's web console or a service listening only on this Mac. None of
// those expect a stranger, so an agent's tabs are kept to the public web:
//
//   - the address it asks to open or go to (AgentRules.address);
//   - every document its tabs load, redirects and the page's own links too,
//     with the name looked up first (AgentControl.vet);
//   - what a page in its tab fetches by itself, by a content rule list
//     (PrivateNetworkRules).
//
// The limits, so they aren't taken for more than they are. A name is looked
// up here and then again by WebKit, so one that answers differently the
// second time (DNS rebinding) gets through. The rule list matches how an
// address is written, not where a name leads, so a page can still fetch
// from a public name that points inside. And through a proxy, it is the
// proxy that looks names up.
//
// Only while an agent has the tab. Handed to you (AgentEnd), it is yours, and
// your own router is yours to visit.

enum PrivateNetwork {
    /// Names that only ever mean this Mac or the network it is on.
    static let localNames = ["localhost", "local", "internal", "home.arpa"]

    /// A host as WebKit would read it: percent-decoded, full-width forms
    /// folded, lower-cased, without brackets or a closing dot.
    nonisolated static func normalised(_ host: String) -> String {
        var out = (host.removingPercentEncoding ?? host).precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "。", with: ".").lowercased()
        if out.hasPrefix("["), out.hasSuffix("]") { out = String(out.dropFirst().dropLast()) }
        while out.hasSuffix(".") { out.removeLast() }
        return out
    }

    /// Whether a host, as written, is private. A name that only resolves to a
    /// private address is not seen here: see `resolvesPrivately`.
    nonisolated static func isPrivate(host: String) -> Bool {
        let host = normalised(host)
        if host.isEmpty { return true }
        if localNames.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        guard let bytes = bytes(of: host) else { return false }
        return isPrivate(bytes: bytes)
    }

    /// The address a host spells, as 4 or 16 bytes; nil for a name. IPv4 in
    /// every form a browser accepts (2130706433, 0x7f.1, 0177.0.0.1).
    nonisolated static func bytes(of host: String) -> [UInt8]? {
        if host.contains(":") {
            var six = in6_addr()
            let plain = String(host.prefix { $0 != "%" })
            guard inet_pton(AF_INET6, plain, &six) == 1 else { return nil }
            return withUnsafeBytes(of: &six) { Array($0) }
        }
        var four = in_addr()
        guard host.split(separator: ".").last?.first?.isNumber == true, inet_aton(host, &four) == 1 else { return nil }
        return withUnsafeBytes(of: &four) { Array($0) }
    }

    /// Loopback, private, link-local, shared (100.64/10, which Tailscale
    /// uses), unspecified, multicast and reserved ranges. Not 198.18/15:
    /// some VPNs answer every name from it.
    nonisolated static func isPrivate(bytes b: [UInt8]) -> Bool {
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
            case (100, 64...127), (172, 16...31): return true
            case (192, 0): return b[2] == 0
            default: return b[0] >= 224
            }
        }
        guard b.count == 16 else { return true }
        let zeros = { (count: Int) in b.prefix(count).allSatisfy { $0 == 0 } }
        // ::, ::1 and the old IPv4-compatible form.
        if zeros(12) { return true }
        // An IPv4 address carried inside: mapped, NAT64, 6to4.
        if zeros(10), b[10] == 0xff, b[11] == 0xff { return isPrivate(bytes: Array(b[12...])) }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
            return isPrivate(bytes: Array(b[12...]))
        }
        if b[0] == 0x20, b[1] == 0x02 { return isPrivate(bytes: Array(b[2..<6])) }
        // Unique local, link-local and the old site-local, multicast.
        if b[0] & 0xfe == 0xfc || b[0] == 0xff { return true }
        return b[0] == 0xfe && b[1] & 0x80 != 0
    }

    /// Every address a name has, by the Mac's resolver. Blocks: never on the
    /// main thread.
    nonisolated static func lookUp(_ host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var out: [[UInt8]] = []
        var next = list
        while let entry = next?.pointee {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.ai_addr, entry.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0,
               let found = bytes(of: String(decoding: text.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)) {
                out.append(found)
            }
            next = entry.ai_next
        }
        return out
    }

    /// Whether any address a name has is private, answered once on the main
    /// thread. No answer in time counts as private: whoever runs the name's
    /// server could otherwise stall this look and answer WebKit's at once. A
    /// name with no address at all is not: there is nowhere for it to go.
    @MainActor
    static func resolvesPrivately(_ host: String, within seconds: TimeInterval = 4,
                                  lookUp: @escaping @Sendable (String) -> [[UInt8]] = { PrivateNetwork.lookUp($0) },
                                  _ done: @escaping @MainActor (Bool) -> Void) {
        let once = Once()
        func answer(_ value: Bool) {
            guard !once.done else { return }
            once.done = true
            done(value)
        }
        let name = normalised(host)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = lookUp(name)
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(found.contains { isPrivate(bytes: $0) }) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { answer(true) } }
    }

    @MainActor private final class Once { var done = false }

    /// Hosts an agent may reach although they are private. None, except in a
    /// test run, whose pages are served from this Mac.
    @MainActor
    static var allowed: Set<String> {
        guard Store.testing else { return [] }
        return Set(Store.settings.stringArray(forKey: "test.agentLocalHosts") ?? [])
    }

    /// Refused to an agent: private, and not let through.
    @MainActor
    static func refuses(_ url: URL, allowed: Set<String>? = nil) -> Bool {
        guard ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let host = normalised(url.host(percentEncoded: false) ?? "")
        if (allowed ?? Self.allowed).contains(host) { return false }
        return isPrivate(host: host)
    }
}

/// The part WebKit's navigation questions never see: what a page fetches by
/// itself (pictures, scripts, fetch, sockets). Added to an agent's tab and
/// taken off when the tab is handed to you.
@MainActor
enum PrivateNetworkRules {
    /// Hosts as WebKit writes them, in the rule list's own small pattern
    /// language, which has no "either of these".
    nonisolated static let hosts: [String] = [
        #"localhost\.?"#, #"[^/:]*\.localhost\.?"#, #"[^/:]*\.local\.?"#, #"[^/:]*\.internal\.?"#, #"[^/:]*\.home\.arpa\.?"#,
        #"127\.[0-9.]+"#, #"10\.[0-9.]+"#, #"0\.[0-9.]+"#, #"192\.168\.[0-9.]+"#, #"169\.254\.[0-9.]+"#,
        #"172\.1[6-9]\.[0-9.]+"#, #"172\.2[0-9]\.[0-9.]+"#, #"172\.3[01]\.[0-9.]+"#,
        #"100\.6[4-9]\.[0-9.]+"#, #"100\.[7-9][0-9]\.[0-9.]+"#, #"100\.1[01][0-9]\.[0-9.]+"#, #"100\.12[0-7]\.[0-9.]+"#,
        #"\[::[^\]]*\]"#, #"\[f[cd][0-9a-f][0-9a-f]:[^\]]*\]"#, #"\[fe[89a-f][0-9a-f]:[^\]]*\]"#,
    ]

    nonisolated static func source(allowing allowed: Set<String>) -> String {
        var rules: [[String: Any]] = hosts.map {
            ["trigger": ["url-filter": "^[a-z]+://\($0)[:/]"], "action": ["type": "block"]]
        }
        for host in allowed.sorted() {
            let literal = NSRegularExpression.escapedPattern(for: host)
            rules.append(["trigger": ["url-filter": "^[a-z]+://\(literal)[:/]"], "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static var compiled: (allowed: Set<String>, list: WKContentRuleList)?

    /// The list, compiled once. Nil if WebKit won't compile it.
    static func ready(_ done: @escaping @MainActor (WKContentRuleList?) -> Void) {
        let allowed = PrivateNetwork.allowed
        if let compiled, compiled.allowed == allowed { return done(compiled.list) }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: allowed.isEmpty ? "agent-private-network" : "agent-private-network-test",
            encodedContentRuleList: source(allowing: allowed)
        ) { list, _ in
            if let list { compiled = (allowed, list) }
            done(list)
        }
    }

    static func add(to tab: Tab) {
        guard let list = compiled?.list else { return }
        tab.web.configuration.userContentController.add(list)
    }

    static func remove(from tab: Tab) {
        guard let list = compiled?.list else { return }
        tab.web.configuration.userContentController.remove(list)
    }
}
