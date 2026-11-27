import Foundation

// Which tabs may be forked (Browser.forkTab): the person's own, and private
// ones, each into the store it is already in. Never an agent's: a task's tabs
// and its store are the task's, and a copy of one made by a keystroke would
// be a tab the task's rules (AgentGate, the private-network refusal) don't
// know about. Never one of the browser's own pages, an extension's page, or a
// tab with no page yet.

enum ForkTab {
    @MainActor
    static func allows(_ tab: Tab) -> Bool {
        guard !tab.agent, !tab.bench, !tab.floating, tab.page == nil, let url = tab.address else { return false }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return true
    }
}
