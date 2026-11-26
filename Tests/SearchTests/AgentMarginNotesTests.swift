import CairnProtocol
import WebKit
import XCTest
@testable import Search

/// Notes in the margin of an agent's page: nothing goes into the page, and
/// there is no way to put one on a tab of the person's.
@MainActor
final class AgentMarginNotesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func note(_ words: String, after: [MarginNote] = [], quote: String = "q") -> MarginNote? {
        MarginNotes.next(after: after, words: words, quote: quote, author: "Claude", page: "https://a.example/x")
    }

    func testNotesAreShortPlainFewAndHideSecrets() throws {
        let long = try XCTUnwrap(note(String(repeating: "a\n", count: 900)))
        XCTAssertLessThanOrEqual(long.words.count, MarginNotes.longestNote + 1)
        XCTAssertFalse(long.words.contains("\n"))
        XCTAssertNil(note("  \n "))
        XCTAssertFalse(try XCTUnwrap(note("key sk-abcdefghijklmnopqrstuvwxyz")).words.contains("sk-abc"))
        var all: [MarginNote] = []
        while let next = note("n", after: all) { all.append(next) }
        XCTAssertEqual(all.count, MarginNotes.most)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    func testTheMarkdownKeepsWordsFromBecomingMarkdown() throws {
        let made = try XCTUnwrap(note("see [here](https://evil.example)", quote: "# <img>"))
        let text = try XCTUnwrap(MarginNotes.markdown([made]))
        XCTAssertEqual(text, "## Margin notes\n\n> \\# \\<img\\>\n\nsee \\[here\\](https://evil.example) (note from Claude)\n")
        XCTAssertNil(MarginNotes.markdown([]))
    }

    func testATabGivesTheNotesOfThePageItIsOn() throws {
        let tab = Tab()
        tab.setAddressOptimistically(try XCTUnwrap(URL(string: "https://a.example/x#part")))
        XCTAssertNil(tab.marginNotesMarkdown)
        tab.marginNotes = [try XCTUnwrap(note("mine"))]
        XCTAssertTrue(tab.marginNotesMarkdown?.contains("mine") == true)
        tab.setAddressOptimistically(try XCTUnwrap(URL(string: "https://a.example/other")))
        XCTAssertNil(tab.marginNotesMarkdown)
        XCTAssertFalse(tab.hasMarginNotes)
    }

    func testCardsDoNotSitOnOneAnother() {
        XCTAssertEqual(MarginNotes.stack(tops: [100, 100, 20], heights: [40, 40, 40]), [100, 146, 20])
        XCTAssertEqual(MarginNotes.stack(tops: [-50], heights: [10]), [6])
    }

    /// The tool, and the check every drive of a tab goes through: a tab of
    /// the person's is refused even when they let the agent see it.
    func testNothingAnnotatesTheirTabs() throws {
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == "annotate_page" })
        XCTAssertEqual(tool.verb, .annotate)
        XCTAssertEqual(Set(tool.passes), ["element", "page", "quote", "note"])
        var consent = AgentConsent()
        consent.hello()
        consent.answer(allow: true, seesTabs: true)
        XCTAssertFalse(consent.may(.drive, own: false))
        XCTAssertEqual(AgentRules.refusal(for: Tab(), own: false, consent: consent, use: .drive), "not_yours")
    }

    func testTheShortcutIsItsOwn() {
        let key = Command.named("view.marginNotes")?.defaultKey
        XCTAssertEqual(key, KeyCombo("a", option: true))
        XCTAssertEqual(key?.command, true, "⌥A alone types a letter in a field")
        XCTAssertEqual(Command.all.filter { $0.defaultKey == key }.count, 1)
    }

    // MARK: - in a page

    private func page(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        PageRoom.shared.made().contentView?.addSubview(web)
        web.loadHTMLString(html, baseURL: URL(string: "https://agent-test.invalid/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        return web
    }

    private func run(_ web: WKWebView, _ script: String) async throws -> [String: Any] {
        let value = try await web.evaluateJavaScript(script, contentWorld: Web.world)
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testAnchoringFindsThePartAndLeavesThePageAsItWas() async throws {
        let web = try await page("""
            <!doctype html><div id=wrap><p>Opening words.</p><p id=p>The   fee is 40 pounds a month.</p></div>
            <p style="display:none">secret clause</p><label>Name <input value="typed-by-you"></label>
            """)
        defer { web.removeFromSuperview() }
        let before = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let found = try await run(web, MarginNotes.anchor(id: 1, key: "__test", snap: nil, index: nil, quote: "fee is 40 pounds"))
        XCTAssertEqual(found["quote"] as? String, "The fee is 40 pounds a month.")
        for missing in ["secret clause", "not on the page", "a"] {
            let out = try await run(web, MarginNotes.anchor(id: 2, key: "__test", snap: nil, index: nil, quote: missing))
            XCTAssertEqual(out["error"] as? String, "no_quote", missing)
        }
        let read = try await run(web, PageScripts.read(key: "__test", snap: 1, most: 20, longest: 10, text: false))
        let field = try XCTUnwrap((read["nodes"] as? [[String: Any]])?.first { $0["role"] as? String == "textbox" }?["e"] as? Int)
        let onField = try await run(web, MarginNotes.anchor(id: 3, key: "__test", snap: 1, index: field, quote: ""))
        XCTAssertEqual(onField["quote"] as? String, "Name", "what is in a field is not quoted")
        let places = try await run(web, MarginNotes.places([1, 2, 3]))
        XCTAssertEqual((places["places"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }, [1, 3])
        let after = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        XCTAssertEqual(before, after, "nothing goes into the page")
        let seen = try await web.evaluateJavaScript("typeof window.__searchNotes") as? String
        XCTAssertEqual(seen, "undefined")
    }

    func testTheViewTakesNoClicksAndSitsUnderTheAgentsHand() throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let hand = AgentOverlayView.over(web)
        let view = MarginNotesView.over(web)
        view.draw([(try XCTUnwrap(note("n")), CGRect(x: 10, y: 20, width: 100, height: 20))])
        XCTAssertNil(view.hitTest(NSPoint(x: 590, y: 25)))
        XCTAssertEqual(view.drawn.count, 1)
        XCTAssertLessThan(try XCTUnwrap(web.subviews.firstIndex(of: view)), try XCTUnwrap(web.subviews.firstIndex(of: hand)))
        // The hand's marks go at hand-over; the notes stay with the tab.
        AgentOverlayView.remove(from: web)
        XCTAssertTrue(web.subviews.contains(view))
    }
}
