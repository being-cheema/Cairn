import Foundation
import WebKit

// One agent task's tabs, and the store they share.
//
// Three kinds of website data, and only one of them an agent's:
//
//   - yours: your own persistent store, and each space's. Nothing here ever
//     hands one to an agent's tab; the most an agent does with a tab of
//     yours is read it, if you let it (AgentRules.refusal).
//   - a task's: this one, made when the task opens its first tab. It is
//     non-persistent, so it starts signed in to nothing and never reaches
//     the disk. It goes with the last tab that holds it.
//   - a private tab's, which no agent sees at all.
//
// Every tab an agent drives is made or taken in here, so "which tabs are
// the agent's" and "which store are they in" are answered in one place.
// What the agent may do with them is AgentControl's.

@MainActor
final class AgentWorkspaceCoordinator {
    /// The tabs it may drive: those opened for it, and those their pages
    /// opened. Empty again once they are handed over or closed.
    private(set) var own: Set<Tab.ID> = []
    /// The task's store; nil before the first tab and after the task ends.
    private(set) var store: WKWebsiteDataStore?
    /// Its tabs are in your hands, to sign in (Pass the Baton).
    private(set) var batonWithYou = false

    /// Parked ones too: a space you have left keeps its row running.
    private var tabs: [Tab] { Browsers.all.flatMap { $0.tabs + $0.parkedTabs }.filter { own.contains($0.id) } }

    /// The task's tabs put in your hands, or taken back. All of them: a
    /// sign-in often opens a window of its own.
    func passBaton(toYou: Bool) {
        batonWithYou = toYou
        for tab in tabs { tab.inYourHands = toYou }
    }

    /// The task's tabs still open, with their pages.
    var openTabs: [Tab] { tabs }

    /// A new tab of the task's, in its store, kept to the public web
    /// (PrivateNetworkRules, which must be ready first).
    func open(_ url: URL, in browser: Browser) -> Tab {
        let store = self.store ?? .nonPersistent()
        self.store = store
        let tab = browser.benchOpen(url, agent: true, store: store)
        own.insert(tab.id)
        PrivateNetworkRules.add(to: tab)
        // The exceptions for a local site you turned the Dev Bridge on for.
        DevBridge.shared.dress(tab)
        return tab
    }

    /// A tab one of its pages opened (Browser's createWebViewWith, which
    /// makes it from the opener's own configuration, and so in its store).
    /// False when the opener isn't the task's.
    func adopt(_ tab: Tab, from opener: Tab) -> Bool {
        guard own.contains(opener.id) else { return false }
        own.insert(tab.id)
        tab.inYourHands = batonWithYou
        PrivateNetworkRules.add(to: tab)
        DevBridge.shared.dress(tab)
        return true
    }

    /// A tab the agent closed.
    func forget(_ id: Tab.ID) { own.remove(id) }

    /// Only those still open are its.
    func forgetClosed(in browser: Browser) {
        own.formIntersection((browser.tabs + browser.parkedTabs).map(\.id))
    }

    /// The task finished: its tabs stay, as yours. They leave `own`, so
    /// nothing the agent said can reach them again, and your own network is
    /// yours to reach from them. They keep the task's store: nothing of
    /// yours comes into them. Returns them, each with the window it is in.
    /// Nil when there was no task store, and so nothing to hand over.
    func handOver() -> [(browser: Browser, tab: Tab)]? {
        guard store != nil else { return nil }
        var released: [(browser: Browser, tab: Tab)] = []
        for browser in Browsers.all {
            for tab in browser.tabs + browser.parkedTabs where own.contains(tab.id) {
                tab.agentWorking = false
                tab.inYourHands = false
                if let web = tab.built { AgentOverlayView.remove(from: web) }
                DevBridge.shared.release(tab)
                PrivateNetworkRules.remove(from: tab)
                released.append((browser, tab))
            }
        }
        own = []
        store = nil
        batonWithYou = false
        return released
    }

    /// The task is over without them: its tabs close, and the store goes
    /// with them, cookies and all. Only with a task store: without one the
    /// tabs are left as they always were.
    func close() {
        guard store != nil else { return }
        for browser in Browsers.all {
            for tab in browser.tabs + browser.parkedTabs where own.contains(tab.id) {
                DevBridge.shared.release(tab)
                browser.closeTaskTab(tab)
            }
        }
        own = []
        store = nil
    }
}
