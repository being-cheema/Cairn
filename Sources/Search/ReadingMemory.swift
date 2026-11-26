import AppKit
import SwiftUI
import WebKit

// Reading memory: the words of pages you have stayed on, kept on this Mac so
// you can find them again by what they said ("? " in the address field), see
// them in Spotlight, and attach them to a message to Claude ("@memory").
//
// Off until you turn it on, and Spotlight is a switch of its own. Only your
// own ordinary tabs are looked at: never a private one, never an agent's,
// never one of a space with sign-ins of its own or of another profile, never
// a page on this Mac or your network, and never a page with a password, card
// or one-time-code field, a payment company's frame or a text editor on it.
// What is typed into boxes is not part of what is read (AIPage). No agent has
// a way to ask for any of it: it reaches Claude only attached to a message of
// yours, as page text, when you press Send.

enum MemoryRules {
    /// How long a page is in front of you before it counts as read.
    static let dwell: TimeInterval = 8
    /// Less text than this is a menu, not something read.
    static let shortest = 600
    static let longest = 40_000

    /// The address a page is kept under, or nil when it isn't to be kept. One
    /// with a token or a code in it is a private link: not kept at all.
    static func address(_ url: URL, isBlocked: (String) -> Bool = HostBlock.isBlocked) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = url.host(percentEncoded: false), !PrivateNetwork.isPrivate(host: host), !isBlocked(host),
              parts.user == nil, parts.password == nil,
              AgentRules.url(url.absoluteString) == url.absoluteString,
              TypedSecrets.hidden(in: url.absoluteString) == url.absoluteString
        else { return nil }
        parts.fragment = nil
        return parts.string
    }

    /// What a "? " in the address field asks the memory, or nil when that
    /// isn't what is being typed.
    static func question(in typed: String) -> String? {
        guard typed.hasPrefix("? ") || typed == "?" else { return nil }
        return typed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// Whether the page holds anything that makes it one not to keep. Run in
    /// the browser's own world, with its test for a secret field; frames of
    /// the page's own site are looked into, others can only be known by
    /// where they come from.
    static var screen: String {
        PageScripts.helpers + #"""
        (function () {
          var roots = [document], seen = 0;
          while (roots.length) {
            var all = roots.shift().querySelectorAll('*');
            for (var i = 0; i < all.length; i++) {
              if (++seen > 60000) return 'too-big';
              var el = all[i], t = el.tagName;
              if (el.shadowRoot) roots.push(el.shadowRoot);
              if (t === 'INPUT' || t === 'TEXTAREA' || t === 'SELECT') {
                var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
                if (secret(el) || (el.type || '').toLowerCase() === 'password' || /(^|\s)(cc-|one-time-code|current-password|new-password)/.test(ac))
                  return 'secret';
              }
              if (t === 'IFRAME') {
                if (/stripe|paypal|braintree|adyen|checkout|recurly|chargebee|squareup|klarna|payment/i.test(el.getAttribute('src') || '')) return 'payment';
                try { if (el.contentDocument) roots.push(el.contentDocument); } catch (e) {}
              }
              var edits = el.getAttribute('contenteditable');
              if (edits !== null && edits !== 'false') return 'editor';
            }
          }
          if (document.designMode === 'on') return 'editor';
          return 'ok';
        })()
        """#
    }
}

@MainActor
final class ReadingMemory: ObservableObject {
    static let shared = ReadingMemory()

    static let onKey = "memory.on"
    static let spotlightKey = "memory.spotlight"

    @Published private(set) var on: Bool
    @Published private(set) var spotlight: Bool

    let index: MemoryIndex
    private let defaults: UserDefaults
    private var watch: Timer?
    /// The page in front now, since when, and the last one taken.
    private var looking: (tab: Tab.ID, address: String, since: Date)?
    private var taken: String?

    init(defaults: UserDefaults = Store.settings, index: MemoryIndex? = nil) {
        self.defaults = defaults
        self.index = index ?? MemoryIndex(folder: Store.file("Memory"),
                                          spotlight: Store.testing ? NoSpotlight() : SystemSpotlight())
        let on = defaults.bool(forKey: Self.onKey)
        self.on = on
        spotlight = defaults.bool(forKey: Self.spotlightKey)
        if on, spotlight { self.index.setSpotlight(true) }
    }

    /// At launch: nothing at all happens while it is off, beyond finishing a
    /// removal from Spotlight that was asked for and not confirmed.
    func begin() {
        if !Store.testing, SystemSpotlight.removalOwed, !(on && spotlight) { SystemSpotlight().removeAll() }
        if on { watchPages() }
    }

    func turn(_ value: Bool) {
        guard value != on else { return }
        on = value
        defaults.set(value, forKey: Self.onKey)
        if value {
            index.setSpotlight(spotlight)
            watchPages()
        } else {
            // What is on its way is dropped, and Spotlight emptied. What was
            // kept stays until you clear it, and nothing reads it meanwhile.
            index.cancel()
            index.setSpotlight(false)
            watch?.invalidate()
            watch = nil
            looking = nil
        }
    }

    func showInSpotlight(_ value: Bool) {
        spotlight = value
        defaults.set(value, forKey: Self.spotlightKey)
        index.setSpotlight(on && value)
    }

    func clear() {
        index.clear()
        taken = nil
        looking = nil
        objectWillChange.send()
    }

    /// A site closed to agents: what was kept of it goes, as its pin
    /// snapshots and watches do.
    func forget(sites: Set<String>) {
        guard !sites.isEmpty else { return }
        index.remove { VaultedSites.blocks(URL(string: $0), in: sites) }
        objectWillChange.send()
    }

    /// History let go of one page.
    func forget(historyKey key: String) {
        index.remove { address in URL(string: address).map { History.identity(for: $0) == key } ?? false }
    }

    func search(_ words: String, limit: Int = 5) -> [RememberedPage] {
        on ? index.search(words, limit: limit) : []
    }

    /// A result clicked in Spotlight: only an address that is kept here.
    func address(fromSpotlight identifier: String) -> URL? {
        index.page(at: identifier).flatMap { AgentRules.webAddress($0.address) }
    }

    // MARK: noticing what is read

    private func watchPages() {
        guard watch == nil, !Store.testing else { return }
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        watch?.tolerance = 1
    }

    private func look() {
        guard on, NSApp.isActive, let browser = Browsers.all.first(where: { $0.window?.isKeyWindow == true }),
              let tab = browser.active, let address = Self.address(of: tab) else {
            looking = nil
            return
        }
        guard let now = looking, now.tab == tab.id, now.address == address else {
            looking = (tab.id, address, Date())
            return
        }
        guard Date().timeIntervalSince(now.since) > MemoryRules.dwell, taken != address else { return }
        taken = address
        Task { @MainActor [weak self, weak tab] in
            if let self, let tab { await self.take(tab) }
        }
    }

    /// Where a tab's page would be kept, or nil for a tab or a page that is
    /// never read. A private tab, an agent's and a script's have stores or
    /// marks of their own; only your first profile's shared store is yours in
    /// the sense meant here.
    static func address(of tab: Tab) -> String? {
        guard !tab.shy, !tab.bench, !tab.agent, !tab.popup, !tab.loading, tab.failure == nil,
              tab.store === Spaces.store(for: Space.firstID), let url = tab.committed else { return nil }
        return MemoryRules.address(url)
    }

    /// Reads the page in `tab` and keeps it, if it is one to keep before and
    /// after the reading and still the same page. The count is taken before
    /// any of it, so a clear while this reads drops what it read.
    func take(_ tab: Tab) async {
        guard on, let web = tab.built, let address = Self.address(of: tab) else { return }
        let epoch = index.epoch
        guard await Self.screened(web), let read = await AIPage.read(tab), await Self.screened(web),
              on, Self.address(of: tab) == address else { return }
        keep(address: address, title: read.title, text: read.text, epoch: epoch)
    }

    /// What of a read is kept. Shapes of secrets written in a page's own
    /// words are taken out too.
    func keep(address: String, title: String, text: String, epoch: Int) {
        guard on, text.count >= MemoryRules.shortest else { return }
        index.keep(address: address, title: TypedSecrets.hidden(in: title),
                   text: TypedSecrets.hidden(in: String(text.prefix(MemoryRules.longest))), epoch: epoch)
    }

    private static func screened(_ web: WKWebView) async -> Bool {
        let value: Any? = await withCheckedContinuation { done in
            web.evaluateJavaScript(MemoryRules.screen, in: nil, in: Web.world) { done.resume(returning: try? $0.get()) }
        }
        return value as? String == "ok"
    }

    // MARK: what @memory attaches

    static let mostAttached = 4
    static let longestAttached = 2_500

    /// The pages that answer to your message, to go with it as page text.
    func attached(for words: String) -> [Mentions.Attached] {
        let found = search(words, limit: Self.mostAttached)
        guard !found.isEmpty else {
            return [Mentions.Attached(title: "Reading memory", address: "", text: "Nothing saved in the reading memory matched this message.",
                                      addressed: false)]
        }
        return found.map { page in
            let text = String(page.text.prefix(Self.longestAttached))
            return Mentions.Attached(title: "From my reading memory: \(page.title)", address: String(page.address.prefix(300)),
                                     text: text, addressed: AIPage.addressesAI(page.title + "\n" + text))
        }
    }
}

extension Browser {
    /// The rows for "? …" in the address field; nil when the field isn't
    /// asking the memory, and then it does what it always did.
    func memoryOffers(for typed: String, memory: ReadingMemory? = nil) -> [Suggestion]? {
        let memory = memory ?? .shared
        guard memory.on, active?.shy != true, let words = MemoryRules.question(in: typed) else { return nil }
        return memory.search(words, limit: 6).compactMap { page in
            guard let url = URL(string: page.address) else { return nil }
            return Suggestion(key: page.address, title: page.title, url: url, kind: .visited)
        }
    }
}

/// Settings › Privacy › Reading Memory.
struct ReadingMemorySettings: View {
    @ObservedObject private var memory = ReadingMemory.shared
    @State private var kept: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Line("Remember what you read",
                 "Keeps the text of pages you stay on, on this Mac. Search it with “? ” in the address field, or @memory in the Claude panel.") {
                Switch(on: Binding(get: { memory.on }, set: { memory.turn($0) }))
            }
            Rule()
            Line("Show remembered pages in Spotlight", "Their titles, addresses and first lines can then be found from Spotlight.") {
                Switch(on: Binding(get: { memory.spotlight }, set: { memory.showInSpotlight($0) }))
                    .disabled(!memory.on)
            }
            Text("Never from private tabs, agents' tabs, spaces with their own sign-ins, other profiles, pages on your network, or pages with a password, card or code field or a text editor. These checks can miss things: a signed-in page with none of those is kept like any other. Clearing history clears this too.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Pill("Clear Reading Memory") {
                    memory.clear()
                    kept = 0
                }
                if let kept {
                    Text(verbatim: kept == 1 ? "1 page kept" : "\(kept) pages kept")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .onAppear { kept = memory.index.pageCount }
    }
}
