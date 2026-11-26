import XCTest
@testable import Search

/// Two ways an audit found an address could be somewhere you didn't see.
@MainActor
final class AuditLinkTests: XCTestCase {
    /// A word that merely contains the site's letters doesn't name it.
    func testALinksSiteIsSaidUnlessTheWordsNameItWhole() {
        func shown(_ markdown: String) -> String { String(PanelProse.inline(markdown).characters) }
        XCTAssertEqual(shown("[banana.com](https://a.co/x)"), "banana.com (a.co)")
        XCTAssertEqual(shown("[a.co.evil.net](https://a.co/x)"), "a.co.evil.net (a.co)")
        XCTAssertEqual(shown("[read it on a.co](https://a.co/x)"), "read it on a.co")
        XCTAssertEqual(shown("[https://a.co/x](https://a.co/x)"), "https://a.co/x")
        XCTAssertEqual(shown("[a.co.](https://a.co/x)"), "a.co.")
    }

    /// Where it is pasted, a bare address in a page's words would become a
    /// link by itself: it is set as code, which never does.
    func testAnAddressInAPagesWordsIsNotMadeALink() throws {
        let request: [String: Any] = ["kind": "brief", "title": "See www.evil.example now",
                                      "sections": [["heading": "H", "body": "Go to https://evil.example/pay today."]]]
        let card = try XCTUnwrap(try? Artifact.parse(request, source: { _ in nil }).get())
        let text = card.markdown
        XCTAssertTrue(text.contains("`www.evil.example`"), text)
        XCTAssertTrue(text.contains("`https://evil.example/pay`"), text)
    }
}
