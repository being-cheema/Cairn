import WebKit
import XCTest
@testable import Search

/// Inspect Style: what is read from a page that is never on screen, and what
/// may be pasted from it.
@MainActor
final class PageStyleTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    func testAFontsNameCannotLeaveItsQuotes() {
        XCTAssertEqual(PageStyle.stack(#"Inter, "Helvetica Neue", sans-serif"#), #""Inter", "Helvetica Neue", sans-serif"#)
        let hostile = PageStyle.stack(#""a\"; } body { display:none } /*", serif"#) ?? ""
        for never in [";", "{", "}", "\\", "*", "\n", ":"] { XCTAssertFalse(hostile.contains(never), never) }
        XCTAssertEqual(hostile.filter { $0 == "\"" }.count, 2)
        XCTAssertNil(PageStyle.stack("\"{}\""))
    }

    func testWhatIsCopied() throws {
        let style = try XCTUnwrap(PageStyle.from(
            #"{"fonts":[["Inter, serif",9]],"sizes":[[16,400,9],[31.96,700,1]],"colours":[[17,34,51,5],[300,0,0,1],[17,34,51,1]]}"#))
        XCTAssertEqual(style.sizes.map(\.said), ["32px / 700", "16px"])
        XCTAssertEqual(style.colours.map(\.hex), ["#112233"], "out of range and twice are left out")
        XCTAssertEqual(style.css, """
        :root {
          --font-1: "Inter", serif;
          --size-1: 32px;
          --weight-1: 700;
          --size-2: 16px;
          --weight-2: 400;
          --color-1: #112233;
        }

        """)
        XCTAssertEqual(style.swiftUI, "let color1 = Color(red: 17 / 255, green: 34 / 255, blue: 51 / 255) // #112233\n")
        XCTAssertNil(PageStyle.from("nonsense"))
        XCTAssertNil(PageStyle.from(nil))
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        let done: XCTestExpectation
        init(_ done: XCTestExpectation) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done.fulfill() }
    }

    func testReadFromAPage() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let loaded = expectation(description: "loaded")
        let delegate = Loaded(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString("""
        <style>body{background:#fafafa;color:rgb(10,20,30);font:16px Georgia,serif}h1{font:700 32px Menlo,monospace}
        .x{display:none;color:#ff0000;font-size:77px}</style><body><h1>Head</h1><p>Plenty of words to be read here.</p>
        <p class="x">unseen</p></body>
        """, baseURL: nil)
        wait(for: [loaded], timeout: 20)
        let read = expectation(description: "read")
        var style: PageStyle?
        PageStyle.read(web) {
            style = $0
            read.fulfill()
        }
        wait(for: [read], timeout: 20)
        withExtendedLifetime(delegate) {}
        let found = try XCTUnwrap(style)
        XCTAssertEqual(found.fonts.first, "\"Georgia\", serif")
        XCTAssertEqual(found.sizes.map(\.said), ["32px / 700", "16px"])
        XCTAssertTrue(found.colours.contains { $0.hex == "#fafafa" }, "\(found.colours)")
        XCTAssertTrue(found.colours.contains { $0.hex == "#0a141e" }, "\(found.colours)")
        XCTAssertFalse(found.colours.contains { $0.hex == "#ff0000" })
    }
}
