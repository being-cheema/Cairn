import WebKit
import XCTest
@testable import Search

@MainActor
final class AgentArchetypeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func page(_ html: String, url: String = "https://agent-test.invalid/") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 900), configuration: configuration)
        PageRoom.shared.made().contentView?.addSubview(web)
        web.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        return web
    }

    private func run(_ web: WKWebView, _ script: String) async throws -> [String: Any] {
        let value = try await web.evaluateJavaScript(script, contentWorld: Web.world)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value as? String).utf8)) as? [String: Any])
    }

    private func kind(_ html: String, url: String = "https://agent-test.invalid/") async throws -> [String: Any]? {
        let web = try await page(html, url: url)
        return try await run(web, PageScripts.archetype())["archetype"] as? [String: Any]
    }

    func testALoginFormIsOneAndItsPasswordIsMarkedSecret() async throws {
        let found = try await kind("<form><label>Email <input type=email></label><label>Password <input type=password></label><button>Sign in</button></form>")
        XCTAssertEqual(found?["type"] as? String, "login")
        let fields = (found?["fields"] as? [String: Any])?["fields"] as? [[String: Any]]
        XCTAssertEqual(fields?.count, 2)
        XCTAssertEqual(fields?.last?["secret"] as? Bool, true)
        XCTAssertNil(fields?.last?["value"])
    }

    func testAProductAnArticleAndAnErrorAreTold() async throws {
        let product = try await kind("""
            <script type="application/ld+json">{"@type":"Product","name":"Teapot","offers":{"price":"19.90","priceCurrency":"EUR"}}</script>
            <h1>Teapot</h1><button>Add to cart</button>
            """)
        XCTAssertEqual(product?["type"] as? String, "product")
        XCTAssertEqual((product?["fields"] as? [String: Any])?["price"] as? String, "19.90")
        let article = try await kind("<article><h1>A long read</h1><p>" + String(repeating: "word ", count: 500) + "</p></article>")
        XCTAssertEqual(article?["type"] as? String, "article")
        let error = try await kind("<title>404 Not Found</title><h1>Not found</h1>")
        XCTAssertEqual(error?["type"] as? String, "error")
        let none = try await kind("<p>hello</p>")
        XCTAssertNil(none)
    }

    func testSearchResultsListTheirLinks() async throws {
        let found = try await kind("""
            <main><form role=search><input type=search name=q></form><ol>
            \((1...8).map { "<li><a href='/r\($0)'>Result number \($0)</a></li>" }.joined())</ol></main>
            """, url: "https://agent-test.invalid/?q=owls")
        XCTAssertEqual(found?["type"] as? String, "search_results")
        let fields = found?["fields"] as? [String: Any]
        XCTAssertEqual(fields?["query"] as? String, "owls")
        XCTAssertEqual((fields?["results"] as? [Any])?.count, 8)
    }

    func testTheBudgetCutsTheLongestListFirstAndSaysSo() {
        let results = (0..<20).map { ["eid": "0000000\($0 % 10)", "title": String(repeating: "t", count: 80), "href": "https://a.example/\($0)"] }
        let summary: [String: Any] = ["type": "search_results", "confidence": "medium", "fields": ["query": "q", "results": results]]
        let fitted = ArchetypeBudget.fit(summary, tokens: 200)
        XCTAssertLessThanOrEqual(ArchetypeBudget.tokens(fitted), 200)
        XCTAssertEqual(fitted["truncated"] as? Bool, true)
        XCTAssertEqual(fitted["type"] as? String, "search_results")
        XCTAssertNotNil((fitted["fields"] as? [String: Any])?["results"])
        XCTAssertNil(ArchetypeBudget.fit(summary, tokens: 100_000)["truncated"])
    }

    func testZoomGivesTheCardAroundAControlAtFullSize() async throws {
        let web = try await page("""
            <ul><li><h3>Teapot</h3><p>Fine china, 1 litre.</p><button>Add</button></li>
            <li><h3>Cup</h3><p>Small.</p><input aria-label=Qty value=2><input type=password aria-label=Pin value=1234></li></ul>
            """)
        let read = try await run(web, PageScripts.read(key: "__t", snap: 1, most: 50, longest: 10, text: false))
        let nodes = read["nodes"] as? [[String: Any]] ?? []
        let eid = try XCTUnwrap(nodes.first { $0["name"] as? String == "Qty" }?["eid"] as? String)
        let out = try await run(web, PageScripts.zoom(key: "__t", eid: eid, chars: 400))
        XCTAssertTrue((out["text"] as? String ?? "").contains("Small."))
        XCTAssertFalse((out["text"] as? String ?? "").contains("Teapot"), "only that card")
        let controls = out["controls"] as? [[String: Any]] ?? []
        XCTAssertEqual(controls.count, 3, "the heading, the quantity and the pin")
        XCTAssertEqual(controls.first { $0["name"] as? String == "Pin" }?["redacted"] as? Bool, true)
        XCTAssertFalse(String(describing: out).contains("1234"))
    }
}
