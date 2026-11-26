import WebKit
import XCTest
@testable import Search

/// The ways out of an agent's tab that an audit found: a space rule, a space
/// switch, a modified click, an extension, another tab spending your Approve,
/// and an agent that goes away while you are signing in.
@MainActor
final class AgentIsolationTests: XCTestCase {
    private var browsers: [Browser] = []
    private var restore: (() -> Void)?

    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    override func tearDown() async throws {
        for browser in browsers {
            browser.closeAll()
            Browsers.discard(browser)
        }
        browsers.removeAll()
        restore?()
        restore = nil
        try await super.tearDown()
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let before = (prefs.usesSpaces, prefs.sendsLinksToSpaces, prefs.spaceRoutes, prefs.peeksLinks, prefs.splitView)
        restore = {
            (prefs.usesSpaces, prefs.sendsLinksToSpaces, prefs.spaceRoutes, prefs.peeksLinks, prefs.splitView) = before
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        // As a window on screen is: the task finds its tabs through this.
        Browsers.register(browser)
        browser.prefs.usesSpaces = true
        return browser
    }

    private func agentTab(in browser: Browser, _ workspace: AgentWorkspaceCoordinator) throws -> Tab {
        workspace.open(try XCTUnwrap(URL(string: "about:blank")), in: browser)
    }

    // MARK: - a space rule

    func testAnAgentsLinkIsNeverSentToAnotherSpace() throws {
        let browser = makeBrowser()
        let home = browser.spaceID
        browser.addSpace(named: "Elsewhere")
        let elsewhere = browser.spaceID
        browser.switchSpace(to: home)
        browser.prefs.sendsLinksToSpaces = true
        browser.prefs.spaceRoutes = [SpaceRoute(site: "example.invalid", space: elsewhere)]
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        let link = try XCTUnwrap(URL(string: "https://example.invalid/page"))
        XCTAssertNotNil(SpaceRoutes.space(for: link), "the rule is on, or this test shows nothing")

        XCTAssertFalse(browser.sendToSpace(link, from: theirs), "it would load with that space's sign-ins")
        XCTAssertEqual(browser.spaceID, home)
    }

    // MARK: - a space switch

    func testATasksTabsAreStillItsOwnOnAnotherSpace() throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        browser.addSpace(named: "Elsewhere")
        XCTAssertFalse(browser.tabs.contains { $0 === theirs }, "parked, or this test shows nothing")

        XCTAssertEqual(workspace.openTabs.map(\.id), [theirs.id])
        workspace.passBaton(toYou: true)
        XCTAssertTrue(theirs.inYourHands)
        workspace.passBaton(toYou: false)
        XCTAssertFalse(theirs.inYourHands, "taken back, wherever it is")
    }

    /// Listing tabs must not make a parked one stop being the task's, which
    /// would take the agent's rules off its page.
    func testTidyingKeepsTabsOnAnotherSpace() throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        browser.addSpace(named: "Elsewhere")

        workspace.forgetClosed(in: browser)
        XCTAssertEqual(workspace.own, [theirs.id])
    }

    func testStopClosesATasksTabsOnAnotherSpace() throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        _ = theirs.web
        browser.addSpace(named: "Elsewhere")

        workspace.close()
        XCTAssertNil(theirs.built, "its page is gone")
        XCTAssertFalse(browser.parkedTabs.contains { $0 === theirs })
    }

    func testAFinishedTaskHandsOverTabsOnAnotherSpace() throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        browser.addSpace(named: "Elsewhere")

        let released = try XCTUnwrap(workspace.handOver())
        XCTAssertEqual(released.map(\.tab.id), [theirs.id])
    }

    /// What holds for an agent's page holds while its space is away: here,
    /// that it never loads a file.
    func testAParkedAgentTabIsStillKeptToTheWeb() async throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        let web = theirs.web
        browser.addSpace(named: "Elsewhere")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agent-parked-\(UUID().uuidString).html")
        try Data("<title>read from disk</title>".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        web.loadFileURL(file, allowingReadAccessTo: file)
        try await Task.sleep(for: .seconds(2))
        XCTAssertNotEqual(web.title, "read from disk")
    }

    /// A question from its page is still answered for you, and at once: held
    /// for a visit to that space, the agent's call would wait on you.
    func testAParkedAgentTabsQuestionIsDismissedAtOnce() async throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        let web = theirs.web
        try await Task.sleep(for: .milliseconds(500))
        browser.addSpace(named: "Elsewhere")

        final class Heard { var answered = false }
        let heard = Heard()
        web.evaluateJavaScript("confirm('Go on?')") { _, _ in heard.answered = true }
        for _ in 0..<30 where !heard.answered { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(heard.answered)
    }

    // MARK: - a modified click

    func testAMiddleClickOnAnAgentsPageStaysInTheTasksStore() throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        let before = Set(browser.tabs.map(\.id))

        theirs.onMiddleClick?(theirs, try XCTUnwrap(URL(string: "https://example.invalid/next")), false)
        let made = browser.tabs.filter { !before.contains($0.id) }
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made.first?.agent, true)
        XCTAssertTrue(made.first?.store === theirs.store, "nothing of yours goes into it")
        XCTAssertFalse(made.first?.store.isPersistent ?? true)
    }

    func testAnAgentsPageCannotOpenAPeek() throws {
        let browser = makeBrowser()
        browser.prefs.peeksLinks = true
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)

        browser.peek(try XCTUnwrap(URL(string: "https://example.invalid/next")), from: theirs)
        XCTAssertNil(browser.peekTab, "a peek has your sign-ins")
    }

    // MARK: - extensions

    func testNoExtensionReachesATasksPages() throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("no extensions before macOS 15.4") }
        XCTAssertNotNil(Web.configuration().webExtensionController, "yours have them, or this test shows nothing")
        XCTAssertNil(Web.configuration(store: .nonPersistent(), isolated: true).webExtensionController)
    }

    func testAnAgentsTabIsNeverSwappedForOneOfYours() throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)

        browser.replace(theirs, going: try XCTUnwrap(URL(string: "https://example.invalid/")))
        XCTAssertTrue(browser.tabs.contains { $0 === theirs })
    }

    // MARK: - your Approve

    func testAnApproveCoversOnlyTheTabItWasAskedAbout() {
        let asked = UUID()
        let form = URL(string: "https://shop.example/order?step=1")
        let grant = NavigationPolicyEngine.SendGrant(tab: asked, to: form, until: 100)
        XCTAssertEqual(grant.until(on: asked, to: form), 100)
        XCTAssertEqual(grant.until(on: UUID(), to: form), 0, "another tab's send is asked about")
    }

    /// An Approve is for the form you were shown: sending anything anywhere
    /// else, from the same tab and in the same moment, is asked about.
    func testAnApproveCoversOnlyTheAddressTheFormWasGoingTo() throws {
        let tab = UUID()
        func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }
        let grant = NavigationPolicyEngine.SendGrant(tab: tab, to: try url("https://shop.example/order"), until: 100)
        XCTAssertEqual(grant.until(on: tab, to: try url("https://SHOP.example/order?token=1")), 100)
        for other in ["https://shop.example/transfer", "https://evil.example/order", "http://shop.example/order",
                      "https://shop.example:8443/order", "https://shop.example.evil.net/order"] {
            XCTAssertEqual(grant.until(on: tab, to: try url(other)), 0, other)
        }
        let unknown = NavigationPolicyEngine.SendGrant(tab: tab, to: nil, until: 100)
        XCTAssertEqual(unknown.until(on: tab, to: try url("https://shop.example/order")), 0,
                       "where it would go wasn't known: the send itself is asked about")
    }

    func testTheQuestionKnowsWhereTheFormWouldGo() throws {
        var target = AgentGate.Target()
        target.tag = "button"
        target.submits = true
        target.inForm = true
        target.method = "post"
        target.action = "https://shop.example/order"
        let page = URL(string: "https://shop.example/cart")
        let submit = AgentGate.hold(click: target, on: page, sites: [], rules: .standard)
        XCTAssertEqual(submit?.sends?.absoluteString, "https://shop.example/order")
        // A button a script acts on: where it sends can't be told from it.
        target.submits = false
        target.type = "button"
        target.label = "Send"
        let scripted = try XCTUnwrap(AgentGate.hold(click: target, on: page, sites: [], rules: .standard))
        XCTAssertNil(scripted.sends)
    }

    /// A button with an address of its own sends there, not to the form's.
    func testAButtonsOwnAddressIsTheOneRead() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        web.loadHTMLString("""
            <form action="/order" method=post><button id=own formaction="/gift">Buy</button><button id=plain>Buy</button></form>
            <form method=post><button id=none>Buy</button></form>
            """, baseURL: URL(string: "https://shop.example/cart"))
        for _ in 0..<50 where (try? await web.evaluateJavaScript("!!document.getElementById('none')")) as? Bool != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        func sends(_ id: String) async throws -> String? {
            _ = try await web.evaluateJavaScript("document.getElementById('\(id)').focus(); true")
            let value = try await web.evaluateJavaScript(PageScripts.focused(), in: nil, contentWorld: Web.world)
            let data = try XCTUnwrap((value as? String)?.data(using: .utf8))
            let out = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return AgentGate.Target(out["gate"])?.action
        }
        let own = try await sends("own"), plain = try await sends("plain"), none = try await sends("none")
        XCTAssertEqual(own, "https://shop.example/gift")
        XCTAssertEqual(plain, "https://shop.example/order")
        XCTAssertEqual(none, "https://shop.example/cart")
    }

    // MARK: - an agent that goes away mid sign-in

    /// Taking the tabs back seals them, and needs no agent to still be there.
    func testTakingTheTabsBackSealsWhatWasTyped() async throws {
        let browser = makeBrowser()
        let workspace = AgentWorkspaceCoordinator()
        let theirs = try agentTab(in: browser, workspace)
        let web = theirs.web
        try await Task.sleep(for: .milliseconds(500))
        web.loadHTMLString("<label>Reply <input id=a value=\"482913\"></label>",
                           baseURL: URL(string: "https://example.invalid/"))
        for _ in 0..<50 where (try? await web.evaluateJavaScript("!!document.getElementById('a')")) as? Bool != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        workspace.passBaton(toYou: true)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            AgentControl.takeBack(workspace) { done.resume() }
        }
        XCTAssertFalse(theirs.inYourHands)
        let read = try await web.evaluateJavaScript(
            PageScripts.read(key: "__t", snap: 1, most: 50, longest: 0, text: false), in: nil, contentWorld: Web.world)
        let seen = try XCTUnwrap(read as? String)
        XCTAssertTrue(seen.contains("Reply"), "the box is read, or this test shows nothing")
        XCTAssertFalse(seen.contains("482913"))
    }
}
