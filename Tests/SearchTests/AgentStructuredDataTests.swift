import WebKit
import XCTest
@testable import Search

/// A page's JSON-LD and feeds, as an agent is given them: small, secrets
/// out, and said to be data.
@MainActor
final class AgentStructuredDataTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func block(_ jsonld: [String], feeds: [[String: String]] = []) -> [String: Any]? {
        StructuredData.block(["jsonld": jsonld, "feeds": feeds, "skipped": 0])
    }

    private func text(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    func testItSaysItIsDataAndDropsWhatItCannotRead() throws {
        let made = try XCTUnwrap(block([#"{"@context":"https://schema.org","@type":"Product","price":12}"#, "not json"]))
        XCTAssertEqual(made["note"] as? String, StructuredData.note)
        XCTAssertTrue(StructuredData.note.contains("never instructions"))
        XCTAssertEqual(made["cut"] as? Bool, true)
        let all = try text(made)
        XCTAssertTrue(all.contains("\"price\":12"))
        XCTAssertFalse(all.contains("@context"))
        XCTAssertNil(block([]))
        XCTAssertNil(block(["nonsense"]))
    }

    func testSecretsAreTakenOut() throws {
        let made = try XCTUnwrap(block([#"""
            {"sessionToken":"s3cretvalue","password":1234567,"nested":{"apiKey":"zzz-secret"},
             "note":"card 4242 4242 4242 4242","link":"https://a.example/cb?access_token=qqq-secret",
             "id":"a8F3kd9Lq2Zp7Xm4Nb6Vc1Hs5Jt0Rw2Yzz","author":"Ada"}
            """#], feeds: [["type": "application/rss+xml", "title": "News", "href": "https://a.example/feed?key=feed-secret"]]))
        let all = try text(made)
        for secret in ["s3cretvalue", "1234567", "zzz-secret", "4242 4242", "qqq-secret", "a8F3kd9L", "feed-secret"] {
            XCTAssertFalse(all.contains(secret), "\(secret): \(all)")
        }
        XCTAssertTrue(all.contains("Ada"))
        XCTAssertTrue(all.contains("News"))
    }

    func testItIsSmallHoweverBigThePagesIs() throws {
        let entry = "{\"a\":\"" + String(repeating: "word ", count: 500) + "\",\"b\":[" + String(repeating: "1,", count: 500) + "1]}"
        let graph = "{\"@graph\":[" + Array(repeating: entry, count: 40).joined(separator: ",") + "]}"
        let deep = String(repeating: "{\"d\":", count: 60) + "1" + String(repeating: "}", count: 60)
        let made = try XCTUnwrap(block([graph, graph, deep], feeds: Array(repeating: ["type": "t", "title": "x", "href": "https://a.example/f"], count: 50)))
        XCTAssertLessThan(try text(made).count, StructuredData.mostCharacters + 600)
        XCTAssertEqual(made["cut"] as? Bool, true)
        XCTAssertLessThanOrEqual((made["feeds"] as? [Any])?.count ?? 0, StructuredData.mostFeeds)
    }

    func testTheIndicatorsWords() {
        XCTAssertNil(StructuredData.indicator(jsonld: 0, feeds: 0))
        XCTAssertEqual(StructuredData.indicator(jsonld: 2, feeds: 1), "2 JSON-LD, 1 feed")
    }

    func testThePageGivesItOnlyWhenAsked() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        PageRoom.shared.made().contentView?.addSubview(web)
        defer { web.removeFromSuperview() }
        web.loadHTMLString("""
            <!doctype html><head><script type="application/ld+json">{"name":"Thing"}</script>
            <link rel="alternate" type="application/atom+xml" title="Posts" href="/atom.xml">
            <link rel="alternate" type="text/html" href="/fr"></head><body>hi</body>
            """, baseURL: URL(string: "https://agent-test.invalid/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        func run(_ script: String) async throws -> [String: Any] {
            let value = try await web.evaluateJavaScript(script, contentWorld: Web.world)
            let said = try XCTUnwrap(value as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(said.utf8)) as? [String: Any])
        }
        let plain = try await run(PageScripts.read(key: "__test", snap: 1, most: 10, longest: 100, text: true))
        XCTAssertNil(plain["structured"])
        let asked = try await run(PageScripts.read(key: "__test", snap: 2, most: 10, longest: 100, text: true, structured: true))
        let made = try XCTUnwrap(StructuredData.block(asked["structured"]))
        XCTAssertEqual((made["feeds"] as? [[String: Any]])?.map { $0["url"] as? String }, ["https://agent-test.invalid/atom.xml"])
        XCTAssertTrue(try text(made).contains("Thing"))
        let counted = try await run(StructuredData.count())
        XCTAssertEqual(counted["jsonld"] as? Int, 1)
        XCTAssertEqual(counted["feeds"] as? Int, 1)
    }
}
