import AppKit
import SwiftUI
import WebKit

// The Local Dev Bridge, live: the grants, kept here and nowhere else; the
// agent tabs they reach, each with its exceptions to the private-network
// rules, the wrappers that listen to its page and what they have said. The
// rules themselves are in DevBridge.swift.

@MainActor
final class DevBridge: ObservableObject {
    static let shared = DevBridge()

    /// The tab each grant was made from, and the origin it is for. Memory
    /// only: nothing of this is ever written down, and it is gone with Cairn.
    @Published private(set) var grants: [Tab.ID: DevOrigin] = [:]
    var origins: Set<DevOrigin> { Set(grants.values) }

    /// Grants waiting for their name to be looked up.
    private var pending: [Tab.ID: DevOrigin] = [:]
    /// The click that last turned it on: one click does it once.
    private var lastClick: TimeInterval = 0
    /// The resolver; a test gives its own.
    var lookUp: @Sendable (String) -> [[UInt8]] = { PrivateNetwork.lookUp($0) }

    /// An agent's tab, for as long as it is the agent's.
    private struct Watched {
        weak var tab: Tab?
        var chain = DevChain()
        var log = DevLog()
        var logOrigin: DevOrigin?
        /// The rule list with the exceptions, while it is on the tab.
        var installed: WKContentRuleList?
    }
    private var watched: [Tab.ID: Watched] = [:]

    private var compiled: (name: String, list: WKContentRuleList)?
    private var compiling: [(name: String, waiting: [@MainActor () -> Void])] = []

    /// What the wrappers' messages travel under, new each launch.
    private let event = "cairn-dev-" + UUID().uuidString.lowercased()

    private init() { purgeLeftovers() }

    // MARK: - your tabs

    /// The origin it could be turned on for from this tab: a local page of
    /// yours, on screen. Never a private tab, nor one an agent opened.
    func offer(for tab: Tab) -> DevOrigin? {
        guard !tab.shy, !tab.agent, tab.built != nil else { return nil }
        return DevOrigin(tab.committed)
    }

    /// The grant made from this tab.
    func granted(from tab: Tab) -> DevOrigin? { grants[tab.id] }

    func isGranted(_ origin: DevOrigin) -> Bool { origins.contains(origin) }

    /// On for what this tab shows, from it or from another.
    func isOn(_ tab: Tab) -> Bool { offer(for: tab).map(isGranted) ?? false }

    /// Turned on from `tab` by your own click on the switch (`view`), which
    /// appeared at `shownAt`: the mouse, on it, in its window, after it had
    /// been there a moment, and each click once (AgentRules.isClick). No key,
    /// no accessibility press, no menu and nothing an agent sends. True when
    /// the click was taken; the grant follows once the name is checked.
    @discardableResult
    func enable(_ tab: Tab, event: NSEvent?, on view: NSView?, shownAt: TimeInterval,
                _ done: @escaping @MainActor (DevOrigin) -> Void = { _ in }) -> Bool {
        guard offer(for: tab) != nil,
              AgentRules.isClick(event, on: view, in: view?.window, after: max(shownAt + 0.5, lastClick)),
              let event else { return false }
        lastClick = event.timestamp
        begin(tab, done)
        return true
    }

    /// The bench's and the tests' way past the click, in a test run only.
    func enableForTest(_ tab: Tab) {
        if Store.testing { begin(tab) }
    }

    private func begin(_ tab: Tab, _ done: @escaping @MainActor (DevOrigin) -> Void = { _ in }) {
        guard let origin = offer(for: tab) else { return }
        pending[tab.id] = origin
        confirm(origin) { [weak self, weak tab] here in
            guard let self, let tab, self.pending.removeValue(forKey: tab.id) == origin,
                  here, self.offer(for: tab) == origin else { return }
            self.change { self.grants[tab.id] = origin }
            done(origin)
        }
    }

    /// Whether the origin's name leads to this Mac and nowhere else. An
    /// address says so itself. No answer in time is a no.
    func confirm(_ origin: DevOrigin, within seconds: TimeInterval = 3, _ done: @escaping @MainActor (Bool) -> Void) {
        if origin.isAddress { return done(true) }
        let once = Once()
        func answer(_ value: Bool) {
            guard !once.done else { return }
            once.done = true
            done(value)
        }
        let look = lookUp, host = origin.host
        DispatchQueue.global(qos: .userInitiated).async {
            let here = DevOrigin.onlyLoopback(look(host))
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(here) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { answer(false) } }
    }

    @MainActor private final class Once { var done = false }

    /// Off for this origin, however many tabs it was turned on from. Any
    /// click or key may: it only takes away.
    func turnOff(_ origin: DevOrigin) {
        pending = pending.filter { $0.value != origin }
        guard isGranted(origin) else { return }
        change { grants = grants.filter { $0.value != origin } }
    }

    /// Stop pressed on an agent: as good as turning it all off.
    func revokeAll() {
        pending = [:]
        if !grants.isEmpty { change { grants = [:] } }
    }

    private func revoke(from id: Tab.ID) {
        pending[id] = nil
        if grants[id] != nil { change { grants[id] = nil } }
    }

    /// The grants, changed: every agent tab's rules and wrappers brought up
    /// to date at once, and one showing a page of an origin no longer granted
    /// is emptied, with its sockets and timers.
    private func change(_ edit: () -> Void) {
        let before = origins
        edit()
        let now = origins
        guard now != before else { return }
        let lost = before.subtracting(now)
        for id in Array(watched.keys) {
            guard let tab = watched[id]?.tab else {
                watched[id] = nil
                continue
            }
            redress(id)
            let on = [tab.committed, tab.address, tab.built?.url].compactMap { DevOrigin($0) }
            if let held = watched[id]?.logOrigin, lost.contains(held) { clear(id) }
            // On any origin granted before, not only the one gone: its page
            // may hold a socket open to the lost one, which no rule closes.
            guard !lost.isEmpty, on.contains(where: before.contains) else {
                tab.rearm()
                continue
            }
            clear(id)
            tab.rearm()
            tab.built?.stopLoading()
            if let blank = URL(string: "about:blank") { tab.built?.load(URLRequest(url: blank)) }
        }
        if !now.isEmpty { ready {} } else { forgetCompiled() }
    }

    /// Nothing granted: the compiled list, which names the origins, goes from
    /// WebKit's store too. A grant is memory only.
    private func forgetCompiled() {
        guard let name = compiled?.name else { return }
        compiled = nil
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: name) { _ in }
    }

    /// Lists a run before this one left, quit or crashed mid-grant: none of
    /// this run's own.
    private func purgeLeftovers() {
        guard let store = WKContentRuleListStore.default() else { return }
        store.getAvailableContentRuleListIdentifiers { [weak self] names in
            MainActor.assumeIsolated {
                for name in names ?? [] where name.hasPrefix(DevRules.prefix) {
                    guard let self, self.compiled?.name != name, !self.compiling.contains(where: { $0.name == name }) else { continue }
                    store.removeContentRuleList(forIdentifier: name) { _ in }
                }
            }
        }
    }

    // MARK: - the tab's life

    /// A tab's view is going: closed, a pin put down or asleep, moved to
    /// another store. A grant made from it goes too; an agent's loses what
    /// was heard and the exceptions on its controller, which outlives the view.
    func viewGone(_ tab: Tab) {
        ElementPicker.cancel(on: tab)
        revoke(from: tab.id)
        if watched[tab.id] != nil {
            undress(tab.id)
            clear(tab.id)
        }
    }

    /// A document arrived in a tab.
    func committed(_ tab: Tab) {
        ElementPicker.cancel(on: tab)
        let origin = DevOrigin(tab.committed)
        if let held = grants[tab.id], held != origin { revoke(from: tab.id) }
        if watched[tab.id] != nil {
            watched[tab.id]?.chain.committed()
            if watched[tab.id]?.logOrigin != origin { clear(tab.id) }
        }
    }

    // MARK: - agent tabs

    /// A tab that is now an agent's (AgentWorkspaceCoordinator), already
    /// under the private-network rules.
    func dress(_ tab: Tab) {
        watched = watched.filter { $0.value.tab != nil }
        watched[tab.id] = Watched(tab: tab)
        redress(tab.id)
    }

    /// No longer an agent's: handed to you, or closed. Nothing of the
    /// bridge's stays on it.
    func release(_ tab: Tab) {
        guard watched[tab.id] != nil else { return }
        undress(tab.id)
        watched[tab.id] = nil
        tab.rearm()
    }

    func isDressed(_ id: Tab.ID) -> Bool { watched[id]?.installed != nil }

    /// The exceptions off a tab, the plain rules back first: never a moment
    /// with neither.
    private func undress(_ id: Tab.ID) {
        guard let installed = watched[id]?.installed, let tab = watched[id]?.tab else { return }
        PrivateNetworkRules.add(to: tab)
        tab.contentController?.remove(installed)
        watched[id]?.installed = nil
    }

    /// The tab's rules as the grants stand: the list with the exceptions in
    /// place of the plain one. Until it is compiled, and if it can't be, the
    /// plain one stays and the local site stays shut.
    private func redress(_ id: Tab.ID) {
        undress(id)
        guard !origins.isEmpty, let compiled, compiled.name == DevRules.identifier(origins),
              let tab = watched[id]?.tab, let controller = tab.contentController else { return }
        controller.add(compiled.list)
        PrivateNetworkRules.remove(from: tab)
        watched[id]?.installed = compiled.list
    }

    /// The rule list for the grants as they stand, compiled; then `done`.
    func ready(_ done: @escaping @MainActor () -> Void) {
        guard !origins.isEmpty else { return done() }
        let name = DevRules.identifier(origins)
        if compiled?.name == name { return done() }
        if let index = compiling.firstIndex(where: { $0.name == name }) {
            compiling[index].waiting.append(done)
            return
        }
        compiling.append((name, [done]))
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: name, encodedContentRuleList: DevRules.source(origins, allowing: PrivateNetwork.allowed)
        ) { [weak self] list, _ in
            MainActor.assumeIsolated {
                guard let self, let index = self.compiling.firstIndex(where: { $0.name == name }) else { return }
                let waiting = self.compiling.remove(at: index).waiting
                if let list, !self.origins.isEmpty, DevRules.identifier(self.origins) == name {
                    let old = self.compiled?.name
                    for id in Array(self.watched.keys) { self.undress(id) }
                    self.compiled = (name, list)
                    for id in Array(self.watched.keys) { self.redress(id) }
                    // One compiled list on disk at a time.
                    if let old { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: old) { _ in } }
                } else if list != nil, self.compiled?.name != name {
                    // Made for grants that have changed since: not kept.
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: name) { _ in }
                }
                waiting.forEach { $0() }
            }
        }
    }

    // MARK: - where an agent's tab may go

    /// The load `open` or `navigate` is about to start in `tab`.
    func expect(_ url: URL, on tab: Tab) {
        watched[tab.id]?.chain.expect(url)
    }

    /// The granted origin a navigation in an agent's tab is let into, or nil
    /// when it is not one this lets in, and the private-network rules answer
    /// as they always have (AgentControl.vet).
    func admits(_ action: WKNavigationAction, on tab: Tab) -> DevOrigin? {
        guard let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var entry = watched[tab.id] else { return nil }
        defer { watched[tab.id] = entry }
        // A window yet to be made is no frame of this tab's: it is asked
        // again in the tab it becomes.
        let window = action.targetFrame == nil
        let main = action.targetFrame?.isMainFrame ?? true
        guard let origin = DevOrigin(url), isGranted(origin) else {
            if !window { entry.chain.went(mainFrame: main) }
            return nil
        }
        let from = action.sourceFrame.securityOrigin
        let source = DevSource(scheme: from.protocol, host: from.host, port: from.port)
        // A window its page just opened has no document yet: its opener's.
        let here = tab.committed ?? tab.opener.flatMap { watched[$0]?.tab?.committed }
        if window {
            let at = DevOrigin(here)
            return at == origin && source.origin == origin ? origin : nil
        }
        return entry.chain.admits(url, origin: origin, mainFrame: main, source: source, committed: DevOrigin(here)) ? origin : nil
    }

    /// A frame of another origin, under an agent tab's granted page.
    func keepsOut(_ action: WKNavigationAction, on tab: Tab) -> Bool {
        guard watched[tab.id] != nil, let url = action.request.url, let frame = action.targetFrame else { return false }
        return DevFrames.refuses(url, subframe: !frame.isMainFrame, top: DevOrigin(tab.committed), granted: origins)
    }

    // MARK: - listening

    /// Whether `tab`'s page is listened to: an agent's own, now, and never
    /// after the tab has been in your hands (AgentControl.devRecords).
    private func records(_ tab: Tab) -> Bool {
        watched[tab.id] != nil && AgentControl.shared.devRecords(tab)
    }

    /// The wrappers for the document at `url` in `tab`, if it is to have them
    /// (Tab.arm).
    func scripts(for tab: Tab, to url: URL?) -> [WKUserScript] {
        guard let origin = DevOrigin(url), isGranted(origin), records(tab) else { return [] }
        return [Armed.script(DevScripts.relay(event: event), .atDocumentStart, mainFrameOnly: true, in: Web.world),
                Armed.script(DevScripts.capture(event: event), .atDocumentStart, mainFrameOnly: true, in: .page)]
    }

    /// A message from the wrappers, checked each time: the tab's own view,
    /// its main frame, and the granted origin, which is also the one of the
    /// document the tab holds.
    @discardableResult
    func receive(_ body: Any, for tab: Tab, web: WKWebView?, mainFrame: Bool, source: DevSource) -> Bool {
        guard mainFrame, let web, web === tab.built, records(tab),
              let origin = source.origin, isGranted(origin), DevOrigin(tab.committed) == origin,
              let message = DevMessage.parse(body, at: Date()) else { return false }
        if watched[tab.id]?.logOrigin != origin { clear(tab.id) }
        watched[tab.id]?.logOrigin = origin
        watched[tab.id]?.log.add(message)
        return true
    }

    func log(of id: Tab.ID) -> DevLog { watched[id]?.log ?? DevLog() }

    private func clear(_ id: Tab.ID) {
        watched[id]?.log = DevLog()
        watched[id]?.logOrigin = nil
    }

    /// The tabs are going into your hands: what was heard is dropped and the
    /// wrappers come out of their next documents.
    func seal(_ tabs: [Tab]) {
        for tab in tabs where watched[tab.id] != nil {
            clear(tab.id)
            tab.rearm()
        }
    }
}

/// Cairn's end of the wrappers, in its own world on every tab's controller;
/// what it hears from any tab that isn't being listened to is dropped
/// (DevBridge.receive).
final class DevRelay: NSObject, WKScriptMessageHandler {
    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let tab else { return }
            let from = message.frameInfo.securityOrigin
            DevBridge.shared.receive(message.body, for: tab, web: message.webView, mainFrame: message.frameInfo.isMainFrame,
                                     source: DevSource(scheme: from.protocol, host: from.host, port: from.port))
        }
    }
}

/// Behind the switch's words: a view that takes the mouse and hands over the
/// very event, so the grant can be told to come from a click on it. It takes
/// no key and has no accessibility press.
final class DevClickView: NSView {
    private var action: (NSEvent, NSView, TimeInterval) -> Void
    /// When it appeared, on the clock events are stamped with.
    private var shownAt = ProcessInfo.processInfo.systemUptime

    init(_ action: @escaping (NSEvent, NSView, TimeInterval) -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    /// What it is the switch for; another, and it starts its wait again.
    private var key: AnyHashable?

    func act(_ action: @escaping (NSEvent, NSView, TimeInterval) -> Void, for key: AnyHashable) {
        self.action = action
        // The same view drawn again for another tab is a new switch to that
        // tab: a click is taken only once it has been there a moment.
        if self.key != key { shownAt = ProcessInfo.processInfo.systemUptime }
        self.key = key
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shownAt = ProcessInfo.processInfo.systemUptime
    }

    override var acceptsFirstResponder: Bool { false }
    // The card is a panel that is never key: the first click is a click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { action(event, self, shownAt) }
    override func accessibilityPerformPress() -> Bool { false }
}

/// The switch's words, in the developer bar and on the site card. Off, only a
/// real click on them turns it on (DevClickView): they are no button, so no
/// key and no accessibility press does it. On, they are an ordinary button,
/// since turning it off only takes away.
struct DevBridgeSwitch: View {
    /// What turning it on gives, in plain words.
    static func promise(_ origin: DevOrigin) -> String {
        "Your agent's own tabs may open \(origin.short), read its errors and send it requests. "
            + "A local server may accept changes without a sign-in."
    }

    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var bridge = DevBridge.shared

    var body: some View {
        if let origin = bridge.offer(for: tab) {
            if bridge.isGranted(origin) {
                Button { bridge.turnOff(origin) } label: { words("Bridge On", on: true) }
                    .buttonStyle(.plain)
                    .help("The Dev Bridge is on for \(origin.short)"
                          + (bridge.granted(from: tab) == nil ? ", turned on from another tab" : "") + ". Click to turn it off.")
            } else {
                words("Turn On Bridge", on: false)
                    .overlay(Spot(key: tab.id) { [weak browser] event, view, shownAt in
                        DevBridge.shared.enable(tab, event: event, on: view, shownAt: shownAt) { [weak browser] origin in
                            browser?.announce("Dev Bridge on for \(origin.short), until this tab closes or leaves it")
                        }
                    })
                    .help("Dev Bridge: " + Self.promise(origin))
            }
        }
    }

    private func words(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(on ? Color.white : Palette.ink)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(on ? Palette.accent : Palette.wash, in: Capsule())
            .contentShape(Capsule())
    }

    private struct Spot: NSViewRepresentable {
        let key: Tab.ID
        let action: (NSEvent, NSView, TimeInterval) -> Void
        func makeNSView(context: Context) -> DevClickView {
            let view = DevClickView(action)
            view.act(action, for: key)
            return view
        }
        func updateNSView(_ view: DevClickView, context: Context) { view.act(action, for: key) }
    }
}
