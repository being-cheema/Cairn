import WebKit
import XCTest
@testable import Search

/// Copy Page as Markdown, run in a real page that is never on screen.
@MainActor
final class PageMarkdownTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        let done: XCTestExpectation
        init(_ done: XCTestExpectation) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done.fulfill() }
    }

    private func read(_ html: String, links: Bool = true, most: Int = 400_000) throws -> PageMarkdown.Page {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let loaded = expectation(description: "loaded")
        let delegate = Loaded(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString(html, baseURL: URL(string: "https://example.com/docs/"))
        wait(for: [loaded], timeout: 20)
        let read = expectation(description: "read")
        var page: PageMarkdown.Page?
        PageMarkdown.read(web, links: links, most: most) {
            page = $0
            read.fulfill()
        }
        wait(for: [read], timeout: 20)
        withExtendedLifetime(delegate) {}
        return try XCTUnwrap(page)
    }

    private let filler = String(repeating: "Plain words to read. ", count: 20)

    func testHeadingsParagraphsListsLinksAndCode() throws {
        let page = try read("""
        <title>Doc</title><body><nav><a href="/x">Menu thing</a></nav><main>
        <h1>Title *here*</h1><p>\(filler)</p>
        <p>See <a href="guide(1)">the <b>guide</b></a>, and <a href="javascript:alert(1)">this</a>.</p>
        <ul><li>One<ul><li>Inner</li></ul></li><li>Two</li></ul><ol start="3"><li>Three</li></ol>
        <pre><code class="language-swift">let a = 1
        let b = `2`</code></pre><blockquote><p>Said.</p></blockquote>
        <p># not a heading</p></main><footer>Foot words</footer></body>
        """)
        let text = page.markdown
        XCTAssertTrue(text.contains("# Title \\*here\\*"), text)
        XCTAssertTrue(text.contains("See [the **guide**](https://example.com/docs/guide%281%29), and this."), text)
        XCTAssertTrue(text.contains("- One\n  - Inner\n- Two"), text)
        XCTAssertTrue(text.contains("3. Three"), text)
        XCTAssertTrue(text.contains("```swift\nlet a = 1\n"), text)
        XCTAssertTrue(text.contains("> Said."), text)
        XCTAssertTrue(text.contains("\\# not a heading"), text)
        XCTAssertFalse(text.contains("Menu thing"))
        XCTAssertFalse(text.contains("Foot words"))
        XCTAssertFalse(text.contains("javascript"))
    }

    func testATable() throws {
        let page = try read("<body><table><tr><th>A</th><th>B</th></tr><tr><td>1|x</td><td></td></tr></table></body>")
        XCTAssertEqual(page.markdown, "| A | B |\n| --- | --- |\n| 1\\|x |  |")
    }

    func testNothingYouTypeOrThatIsHiddenIsRead() throws {
        let page = try read("""
        <body><p>Seen.</p><form><label>Password <input type="password" value="hunter2"></label>
        <input autocomplete="cc-number" value="4111111111111111"><input autocomplete="one-time-code" value="493021">
        <textarea>draft words</textarea><select><option>picked</option></select></form>
        <div contenteditable>unsent reply</div><p style="display:none">unseen</p>
        <p aria-hidden="true">hushed</p><iframe srcdoc="<p>framed</p>"></iframe></body>
        """)
        XCTAssertTrue(page.markdown.contains("Seen."), page.markdown)
        for never in ["hunter2", "4111", "493021", "draft words", "picked", "unsent reply", "unseen", "hushed", "framed"] {
            XCTAssertFalse(page.markdown.contains(never), never)
        }
    }

    func testWithoutLinksNoAddressIsKept() throws {
        let page = try read(#"<body><p><a href="/reset?token=abc123">Reset</a></p></body>"#, links: false)
        XCTAssertEqual(page.markdown, "Reset")
    }

    func testALongPageIsCutAtABlock() throws {
        let page = try read("<body><p>first</p><p>\(filler)</p><p>last</p></body>", most: 100)
        XCTAssertEqual(page.markdown, "first")
        XCTAssertTrue(page.cut)
    }

    func testTheTitleHeadsAPageWithNoHeading() {
        let page = PageMarkdown.Page(markdown: "Words.", cut: false, title: " A\nTitle ", url: nil)
        XCTAssertEqual(PageMarkdown.copied(page), "# A Title\n\nWords.\n")
        XCTAssertNil(PageMarkdown.copied(PageMarkdown.Page(markdown: "", cut: false, title: "x", url: nil)))
    }
}
