import WebKit
import XCTest
@testable import Search

/// Listen: how far a skip goes, and the sentences found in a reading page
/// that is never on screen. Nothing is spoken.
@MainActor
final class NarrationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    func testSkippingByGuessedSeconds() {
        // Ten sentences of five seconds each.
        let lengths = Array(repeating: Int(NarrationPlan.lettersPerSecond * 5), count: 10)
        XCTAssertEqual(NarrationPlan.target(from: 0, by: 15, lengths: lengths), 3)
        XCTAssertEqual(NarrationPlan.target(from: 5, by: -15, lengths: lengths), 2)
        XCTAssertEqual(NarrationPlan.target(from: 9, by: 15, lengths: lengths), 9)
        XCTAssertEqual(NarrationPlan.target(from: 1, by: -15, lengths: lengths), 0)
        // One long sentence is still only one along.
        XCTAssertEqual(NarrationPlan.target(from: 0, by: 15, lengths: [5000, 10, 10]), 1)
        XCTAssertEqual(NarrationPlan.target(from: 4, by: 15, lengths: []), 0)
        XCTAssertEqual(NarrationPlan.elapsed(at: 2, lengths: lengths), 10, accuracy: 0.01)
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        let done: XCTestExpectation
        init(_ done: XCTestExpectation) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done.fulfill() }
    }

    private func run(_ web: WKWebView, _ script: String) throws -> [String: Any] {
        let ran = expectation(description: "ran")
        var out: [String: Any]?
        web.evaluateJavaScript(script, in: nil, in: Web.world) { result in
            out = ((try? result.get()) as? String)?.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ran.fulfill()
        }
        wait(for: [ran], timeout: 20)
        return try XCTUnwrap(out)
    }

    func testTheArticlesSentences() throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let loaded = expectation(description: "loaded")
        let delegate = Loaded(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString("""
        <html lang="en"><body><p>Not the article.</p><div id="office-reader"><h1>A title</h1>
        <p class="office-from">example.com</p><p>First one. A <em>second</em> one!</p>
        <pre>let x = 1.</pre><p style="display:none">Unseen.</p><ul><li>An item</li></ul></div></body></html>
        """, baseURL: nil)
        wait(for: [loaded], timeout: 20)
        let out = try run(web, PageScripts.sentences())
        XCTAssertEqual(out["sentences"] as? [String], ["A title", "First one.", "A second one!", "An item"])
        XCTAssertEqual(out["lang"] as? String, "en")
        let box = try run(web, PageScripts.sentence(2, show: true))["box"] as? [Double]
        XCTAssertEqual(box?.count, 4)
        XCTAssertGreaterThan(box?[2] ?? 0, 0)
        XCTAssertEqual(try run(web, PageScripts.sentence(99, show: false))["gone"] as? Bool, true)
        _ = try run(web, "document.getElementById('office-reader').remove(); JSON.stringify({})")
        XCTAssertEqual(try run(web, PageScripts.sentence(2, show: false))["gone"] as? Bool, true)
        withExtendedLifetime(delegate) {}
    }

    func testNothingStartsOutsideReadingMode() {
        Narrator.shared.start(Tab())
        XCTAssertEqual(Narrator.shared.state, .idle)
        XCTAssertNil(Narrator.shared.reading)
    }
}
