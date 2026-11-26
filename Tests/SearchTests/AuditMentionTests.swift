import WebKit
import XCTest
@testable import Search

/// What an audit found about "@": a tab that moved after you named it went
/// under its old name, one that couldn't be read was left out without a word,
/// and a draft being typed in a page's own editor went with the page.
@MainActor
final class AuditMentionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func tab(_ address: String) throws -> Tab {
        let tab = Tab()
        tab.setAddressOptimistically(try XCTUnwrap(URL(string: address)))
        return tab
    }

    func testATabThatMovedSinceYouNamedItIsNotSent() async throws {
        let tab = try tab("https://example.com/named")
        let named = Mention.tab(tab.id, label: "Named", page: Mentions.page(tab))
        tab.setAddressOptimistically(try XCTUnwrap(URL(string: "https://example.com/elsewhere")))

        let got = await Mentions.collect([named], among: [tab])
        XCTAssertTrue(got.attached.isEmpty)
        XCTAssertEqual(got.missing, [named])
    }

    func testAJumpWithinThePageIsTheSamePage() throws {
        let tab = try tab("https://example.com/named#one")
        let before = Mentions.page(tab)
        tab.setAddressOptimistically(try XCTUnwrap(URL(string: "https://example.com/named#two")))
        XCTAssertEqual(Mentions.page(tab), before)
    }

    func testATabThatIsGoneOrAsleepIsSaidToBeMissing() async throws {
        let asleep = try tab("https://example.com/asleep")
        let named = [Mention.tab(asleep.id, label: "Asleep", page: Mentions.page(asleep)),
                     Mention.tab(UUID(), label: "Gone")]
        let got = await Mentions.collect(named, among: [asleep])
        XCTAssertEqual(got.missing, named)
    }

    /// What can't go is not quietly left out of your message.
    func testWhatIsSaidWhenSomethingCannotGo() {
        let said = Mentions.notSent([.tab(UUID(), label: "Prices"), .tab(UUID(), label: "Inbox")])
        XCTAssertTrue(said.contains("@Prices") && said.contains("@Inbox"), said)
        XCTAssertTrue(said.hasPrefix("Not sent"), said)
    }

    func testWhatYouAreTypingInAPagesEditorIsNotRead() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        web.loadHTMLString("""
            <p>Words the page shows.</p>
            <div contenteditable="true"><p>an unsent draft</p></div>
            <div contenteditable=""><span>another draft</span></div>
            """, baseURL: URL(string: "https://example.com/"))
        for _ in 0..<50 where (try? await web.evaluateJavaScript("!!document.querySelector('p')")) as? Bool != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        let value = try await web.evaluateJavaScript(AIPage.script, in: nil, contentWorld: Web.world)
        let text = try XCTUnwrap((value as? [String: Any])?["text"] as? String)
        XCTAssertTrue(text.contains("Words the page shows."), text)
        XCTAssertFalse(text.contains("draft"), text)
    }
}
