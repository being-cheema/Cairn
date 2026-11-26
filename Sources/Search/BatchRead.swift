import Foundation
#if canImport(CairnProtocol)
import CairnProtocol
#endif

// batch_read: a few pages opened and read side by side, for looking only.
//
// This file is what is decided from the request alone. The opening is
// AgentControl's, in the task's own store and through the same address rules,
// private-network refusal and "leaving the task's sites" question as `open`.

/// Where one page of a batch has got to, for its pill in the panel.
struct ScoutProgress: Identifiable, Equatable {
    enum State: Equatable { case waiting, loading, read, failed }
    let id: Int
    let host: String
    var state: State = .waiting

    func said(working: Bool) -> String {
        switch state {
        case .read: return "read"
        case .failed: return "not read"
        case .waiting, .loading: return working ? "loading" : "not read"
        }
    }
}

enum BatchRead {
    static let most = 4
    /// Less of each than one read gives, as there may be four.
    static let nodes = 100
    static let text = 8_000

    static let blocked = AgentRefusal(code: "blocked_host", message: "That site is kept from agents",
                                      hint: "Leave it out, and tell the person.")

    /// The questions opening these in this order would put, as `open` one
    /// after another would: each is measured from the task's sites and the
    /// ones before it.
    static func holds(_ urls: [URL], sites: Set<String>, rules: AgentGate.Rules,
                      registrable: (String) -> String = Vault.registrable) -> [AgentGate.Hold] {
        var sites = sites
        var out: [AgentGate.Hold] = []
        for url in urls {
            if let hold = AgentGate.hold(address: url, sites: sites, rules: rules, registrable: registrable) { out.append(hold) }
            if let site = AgentGate.site(url, registrable: registrable) { sites.insert(site) }
        }
        return out
    }

    /// The addresses a request names, each one `open` would take. One it
    /// wouldn't refuses the lot, before anything is asked or opened.
    @MainActor
    static func urls(_ request: [String: Any], allowed: Set<String>? = nil,
                     isBlocked: (String) -> Bool = HostBlock.isBlocked) -> Result<[URL], AgentRefusal> {
        guard let asked = request["urls"] as? [String], (1...most).contains(asked.count) else {
            return .failure(AgentRefusal(code: "bad_urls", message: "urls is a list of 1 to \(most) addresses"))
        }
        var out: [URL] = []
        for (index, text) in asked.enumerated() {
            switch NavigationPolicyEngine.destination(text, allowed: allowed) {
            case .success(let url):
                if isBlocked(url.host() ?? "") { return .failure(blocked) }
                out.append(url)
            case .failure(.notWeb):
                return .failure(AgentRefusal(code: "refused_address", message: "Address \(index + 1): only http and https addresses",
                                             hint: "Nothing was opened."))
            case .failure(.privateAddress):
                return .failure(AgentRefusal(code: "private_address", message: "Address \(index + 1): not this Mac or a private network",
                                             hint: "Nothing was opened."))
            }
        }
        return .success(out)
    }
}
