import AppKit
import SwiftUI
import UserNotifications
import WebKit

// Pages you asked to be told about: looked at again every so often, and a
// notification when their words change.
//
// Off until switched on (Settings › Privacy › Watch pages for changes), and
// then only the pages you pick, one at a time, from a tab's menu. Never a
// private tab, never a site closed to agents (VaultedSites). Each look is in
// a web store of its own that keeps nothing and starts with nothing: no
// cookie of yours, so what is watched is what a stranger sees. It only reads:
// no click, no form, no download, and no main page sent with data in it.
// The words kept to compare against are PageWords'. Removing a watch,
// switching this off, Clear History or closing the site to agents deletes
// them. Looks happen only while Cairn is running.

struct Watch: Codable, Equatable, Identifiable {
    enum Every: Int, Codable, CaseIterable {
        case quarter = 900, hour = 3600, sixHours = 21600

        var title: String {
            switch self {
            case .quarter: return "Every 15 Minutes"
            case .hour: return "Every Hour"
            case .sixHours: return "Every 6 Hours"
            }
        }
    }

    var id = UUID()
    let url: URL
    var title: String
    var every: Every
    var lastChecked: Date?
    /// The words at the last look; nil before the first.
    var text: String?
    /// The first new line of the last change, to find in the page again.
    var found: String?

    func isDue(_ now: Date) -> Bool {
        // A little early is on time: the system fires when it suits it.
        lastChecked.map { now.timeIntervalSince($0) >= Double(every.rawValue) * 0.9 } ?? true
    }
}

@MainActor
final class PageWatches: ObservableObject {
    static let shared = PageWatches()
    static let key = "pages.watch"
    static let most = 20

    private let file: URL
    /// Whether looks are scheduled and made: not in a test run.
    private let live: Bool
    private let notify: @MainActor (Watch) -> Void
    @Published private(set) var watches: [Watch] = []
    private var scheduler: NSBackgroundActivityScheduler?
    private var looking: [UUID: WatchLook] = [:]

    init(file: URL = Store.file("PageWatchers").appendingPathComponent("watches.json"), live: Bool = !Store.testing,
         notify: @escaping @MainActor (Watch) -> Void = { PageWatches.post($0) }) {
        self.file = file
        self.live = live
        self.notify = notify
        watches = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Watch].self, from: $0) } ?? []
    }

    var on: Bool { Store.settings.bool(forKey: Self.key) }

    /// A page that may be watched at all.
    func may(_ url: URL) -> Bool {
        on && ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
            && url.user == nil && url.password == nil && !VaultedSites.blocks(url, in: VaultedSites.current)
    }

    /// Whether a tab's menu offers it: never for a private tab, nor one of
    /// an agent's or of a store that keeps nothing.
    func offers(_ tab: Tab) -> Bool {
        guard !tab.shy, !tab.agent, !tab.bench, tab.store.isPersistent, let url = tab.pageAddress else { return false }
        return may(url)
    }

    func watch(of url: URL) -> Watch? { watches.first { $0.url == url } }

    /// The person's pick from a tab's menu, and the only way one is added.
    @discardableResult
    func add(_ url: URL, title: String, every: Watch.Every) -> Bool {
        guard may(url) else { return false }
        if let at = watches.firstIndex(where: { $0.url == url }) {
            watches[at].every = every
        } else {
            guard watches.count < Self.most else { return false }
            watches.append(Watch(url: url, title: String(title.prefix(120)), every: every))
        }
        save()
        schedule()
        return true
    }

    func remove(_ id: UUID) {
        watches.removeAll { $0.id == id }
        looking.removeValue(forKey: id)?.end()
        save()
        schedule()
    }

    func removeAll() {
        watches = []
        for look in looking.values { look.end() }
        looking = [:]
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        schedule()
    }

    /// Sites just closed to agents: their watches go, words and all.
    func forget(sites: Set<String>) {
        for watch in watches where VaultedSites.blocks(watch.url, in: sites) { remove(watch.id) }
    }

    private func save() {
        guard !watches.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        if let data = try? JSONEncoder().encode(watches) { PageWords.write(data, to: file) }
    }

    /// What a look found. `said` is nil for a look that failed, which keeps
    /// what there was. True when it changed, and you were told.
    @discardableResult
    func looked(_ id: UUID, said: String?, at now: Date = Date()) -> Bool {
        guard on, let at = watches.firstIndex(where: { $0.id == id }) else { return false }
        watches[at].lastChecked = now
        var changed = false
        if let text = said.map(PageWords.kept), !PageWords.lines(text).isEmpty {
            if let old = watches[at].text {
                if PageWords.changed(from: old, to: text) {
                    changed = true
                    watches[at].found = PageWords.firstAdded(from: old, to: text)
                    watches[at].text = text
                }
            } else {
                watches[at].text = text
            }
        }
        save()
        if changed { notify(watches[at]) }
        return changed
    }

    // MARK: - when

    /// At launch, and whenever the list or the switch moves.
    func schedule() {
        guard live, on, !watches.isEmpty else {
            scheduler?.invalidate()
            scheduler = nil
            return
        }
        guard scheduler == nil else { return }
        let activity = NSBackgroundActivityScheduler(identifier: "\(Brand.bundleID).pagewatch")
        activity.repeats = true
        // The shortest choice; each watch's own is asked at each firing.
        activity.interval = TimeInterval(Watch.Every.quarter.rawValue)
        activity.tolerance = 120
        activity.qualityOfService = .utility
        activity.schedule { done in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PageWatches.shared.lookAtDue() }
                done(.finished)
            }
        }
        scheduler = activity
    }

    func lookAtDue(_ now: Date = Date()) {
        guard live, on else { return }
        // One that has been closed to agents since is dropped, not looked at.
        forget(sites: VaultedSites.current)
        for watch in watches where watch.isDue(now) && looking[watch.id] == nil {
            looking[watch.id] = WatchLook(watch.url) { [weak self] said in
                guard let self else { return }
                looking[watch.id] = nil
                looked(watch.id, said: said)
            }
        }
    }

    // MARK: - telling you

    static let infoKey = "cairn.watch"

    static func post(_ watch: Watch) {
        guard !Store.testing else { return }
        let content = UNMutableNotificationContent()
        content.title = "Page changed"
        content.subtitle = SiteCard.site(watch.url)
        // The page's own name for itself; none of what it says.
        content.body = watch.title
        content.sound = .default
        content.userInfo = [infoKey: watch.id.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "watch.\(watch.id.uuidString)", content: content, trigger: nil))
    }

    /// The notification, clicked: the page in a tab of yours, the changed
    /// part marked.
    func open(_ id: UUID) {
        guard let watch = watches.first(where: { $0.id == id }),
              let browser = Browsers.all.first(where: { $0.window?.isKeyWindow == true }) ?? Browsers.primary else { return }
        NSApp.activate()
        browser.window?.makeKeyAndOrderFront(nil)
        let tab = browser.open(watch.url, foreground: true)
        if let found = watch.found { point(at: found, in: tab, of: browser, tries: 40) }
    }

    private func point(at line: String, in tab: Tab, of browser: Browser, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak tab, weak browser] in
            guard let self, let tab, let browser else { return }
            guard !tab.loading, let web = tab.built else {
                if tries > 0 { point(at: line, in: tab, of: browser, tries: tries - 1) }
                return
            }
            web.evaluateJavaScript(PageScripts.find(line: Self.needle(line)), in: nil, in: Web.world) { [weak web, weak browser] result in
                let box = ((try? result.get()) as? String)?.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { $0["box"] as? [Double] }
                guard let web, let box, let place = AgentOverlayView.place(box, zoom: web.pageZoom * web.magnification) else {
                    // You see the page signed in; the watch didn't.
                    browser?.announce("The changed part isn't on this page as you see it")
                    return
                }
                let overlay = AgentOverlayView.over(web)
                overlay.show("Changed", at: place, spotlight: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak overlay] in overlay?.clear() }
            }
        }
    }

    /// A kept line as the page would show it: the Markdown's own marks off.
    static func needle(_ line: String) -> String {
        var out = line.replacingOccurrences(of: #"^\s*(#{1,6}|-|>|\d+\.|\|)\s+"#, with: "", options: .regularExpression)
        // The first cell of a table's row, which is one thing on the page.
        out = out.components(separatedBy: " | ").first ?? out
        out = out.replacingOccurrences(of: #"(?<!\\)[*`]+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: " |")).prefix(80))
    }
}

extension PageScripts {
    /// The smallest shown block holding `line`, scrolled to, and where it is.
    static func find(line: String) -> String {
        call(#"""
        (function (want) {
          function plain(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }
          var best = null, size = Infinity;
          if (want && document.body) {
            Array.prototype.forEach.call(document.body.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,td,th,pre,blockquote,dd,dt,div,span,a'), function (el) {
              var said = plain(el.innerText);
              if (said.length < size && said.indexOf(want) >= 0 && visible(el)) { best = el; size = said.length; }
            });
          }
          if (!best) return JSON.stringify({ ok: false });
          best.scrollIntoView({ block: 'center' });
          return JSON.stringify({ ok: true, box: boxOf(best) });
        })
        """#, [line])
    }
}

// MARK: - one look

/// One page, loaded off screen in a store that starts empty and keeps
/// nothing, read once, and let go.
@MainActor
final class WatchLook: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView?
    private let watched: URL
    private var done: ((String?) -> Void)?
    /// How long a page is given.
    private static let patience: TimeInterval = 40

    init(_ url: URL, done: @escaping (String?) -> Void) {
        watched = url
        self.done = done
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        self.web = web
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in self?.finish(nil) }
    }

    func end() {
        done = nil
        finish(nil)
    }

    private func finish(_ said: String?) {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
        let call = done
        done = nil
        call?(said)
    }

    /// What a look may load. Pure, for its tests.
    nonisolated static func allows(_ url: URL, watched: URL, method: String, mainFrame: Bool, download: Bool,
                                   vaulted: Set<String>) -> Bool {
        if download || VaultedSites.blocks(url, in: vaulted) { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else { return !mainFrame && ["about", "data", "blob"].contains(scheme) }
        // Reading only: the page itself is never sent anything.
        if mainFrame, !["GET", "HEAD"].contains(method.uppercased()) { return false }
        // A public page can't send an unwatched look into your own network.
        let inside = { (address: URL) in PrivateNetwork.isPrivate(host: address.host(percentEncoded: false) ?? "") }
        return !inside(url) || inside(watched)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let main = action.targetFrame?.isMainFrame ?? true
        guard action.targetFrame != nil, let url = action.request.url,
              Self.allows(url, watched: watched, method: action.request.httpMethod ?? "GET", mainFrame: main,
                          download: action.shouldPerformDownload, vaulted: VaultedSites.current)
        else { return decisionHandler(.cancel) }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let status = (response.response as? HTTPURLResponse)?.statusCode ?? 200
        let fine = response.canShowMIMEType && (!response.isForMainFrame || (200..<300).contains(status))
        decisionHandler(fine ? .allow : .cancel)
        // An error page is not the page changing.
        if !fine, response.isForMainFrame { finish(nil) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A moment for what the page draws once it has loaded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let web, !web.isLoading else { return }
            PageMarkdown.read(web, links: false, most: PageWords.longest) { [weak self] page in
                self?.finish(page?.markdown)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

    // Nothing a page asks for is granted, and nothing waits for you.

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - what shows

/// The tab menu's Watch Page for Changes…, with how often, and the way to
/// stop. Not there while watching is off.
struct PageWatchMenu: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var watches = PageWatches.shared

    var body: some View {
        if watches.offers(tab), let url = tab.pageAddress {
            let held = watches.watch(of: url)
            Menu("Watch Page for Changes…") {
                ForEach(Watch.Every.allCases, id: \.self) { every in
                    Toggle(every.title, isOn: Binding(
                        get: { held?.every == every },
                        // The person's own pick from the menu: nothing else adds one.
                        set: { _ in
                            if watches.add(url, title: tab.label, every: every) {
                                SiteNotifications.shared.authorize()
                                watches.lookAtDue()
                            }
                        }
                    ))
                }
                if let held {
                    Divider()
                    Button("Stop Watching") { watches.remove(held.id) }
                }
            }
        }
    }
}

/// Settings › Privacy: the pages watched, each with a way to stop.
struct PageWatchList: View {
    @ObservedObject private var watches = PageWatches.shared

    var body: some View {
        ForEach(watches.watches) { watch in
            Rule()
            Line(SiteCard.site(watch.url) + (watch.url.path == "/" ? "" : watch.url.path),
                 watch.every.title + (watch.text == nil ? ", not looked at yet" : "")) {
                Pill("Stop Watching") { watches.remove(watch.id) }
            }
        }
    }
}
