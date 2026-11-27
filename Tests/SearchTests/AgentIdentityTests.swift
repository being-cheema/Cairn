import WebKit
import XCTest
@testable import Search

/// eids, the five-point probe, eid resolution and fill_form's script, in a
/// real page.
@MainActor
final class AgentIdentityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func page(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 900), configuration: configuration)
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

    private func read(_ web: WKWebView) async throws -> [[String: Any]] {
        let out = try await run(web, PageScripts.read(key: "__t", snap: 1, most: 100, longest: 100, text: false))
        return out["nodes"] as? [[String: Any]] ?? []
    }

    func testTheSHAIsTheStandards() async throws {
        let web = try await page("<p>x</p>")
        let script = PageScripts.call("(function () { return JSON.stringify({ a: sha256hex('abc'), e: sha256hex(''), "
            + "l: sha256hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq') }); })", [])
        let out = try await run(web, script.replacingOccurrences(of: ")()", with: ")()"))
        XCTAssertEqual(out["a"] as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(out["e"] as? String, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(out["l"] as? String, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testEidsAreEightHexAndUnique() async throws {
        let web = try await page("<main><ul><li><button>Add</button></li><li><button>Add</button></li><li><button>Add</button></li></ul></main>")
        let nodes = try await read(web)
        let ids = nodes.compactMap { $0["eid"] as? String }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3, "look-alikes are told apart")
        for id in ids { XCTAssertNotNil(id.range(of: "^[0-9a-f]{8}$", options: .regularExpression)) }
    }

    func testAnEidSurvivesARedrawAndAWrapper() async throws {
        let web = try await page("<main><form><label>Email <input id=a></label><button>Go</button></form></main>")
        let before = try await read(web).compactMap { $0["eid"] as? String }
        _ = try await web.evaluateJavaScript("""
            var m = document.querySelector('main'), f = document.querySelector('form');
            var w = document.createElement('div'); m.replaceChild(w, f); w.appendChild(f.cloneNode(true)); null;
            """)
        let after = try await read(web).compactMap { $0["eid"] as? String }
        XCTAssertEqual(before, after)
    }

    func testTheProbeSeesWhatCoversAControl() async throws {
        let web = try await page("""
            <button id=a style="position:absolute;left:10px;top:10px;width:100px;height:40px">Open</button>
            <button id=b style="position:absolute;left:10px;top:100px;width:100px;height:40px">Under</button>
            <div style="position:absolute;left:0;top:90px;width:300px;height:70px;background:#eee">Cover</div>
            <button id=c style="position:absolute;left:10px;top:2000px">Far</button>
            """)
        let nodes = try await read(web)
        func node(_ name: String) -> [String: Any]? { nodes.first { $0["name"] as? String == name } }
        XCTAssertEqual(node("Open")?["hit_testable"] as? Bool, true)
        XCTAssertNil(node("Open")?["occluded_by"])
        XCTAssertEqual(node("Under")?["hit_testable"] as? Bool, false)
        XCTAssertEqual(node("Far")?["hit_testable"] as? Bool, false)
    }

    func testAnEidNamesTheElementAgain() async throws {
        let web = try await page("<main><button>One</button><button>Two</button></main>")
        let nodes = try await read(web)
        let two = try XCTUnwrap(nodes.first { $0["name"] as? String == "Two" }?["eid"] as? String)
        let found = try await run(web, PageScripts.resolve(key: "__t", eid: two))
        XCTAssertEqual(found["index"] as? Int, 1)
        let none = try await run(web, PageScripts.resolve(key: "__t", eid: "00000000"))
        XCTAssertEqual(none["error"] as? String, "detached")
    }

    func testFillSetsThroughTheSetterAndNeverASecret() async throws {
        let web = try await page("""
            <form><label>Name <input id=n required></label><label>Colour <select id=s><option>red<option>blue</select></label>
            <label><input id=k type=checkbox> Agree</label><label>Password <input id=p type=password></label></form>
            <script>window.seen=[];document.getElementById('n').addEventListener('input',function(){seen.push('input')});
            document.getElementById('n').addEventListener('change',function(){seen.push('change')});</script>
            """)
        _ = try await read(web)
        func fields(_ items: [(Int, String)]) -> [[String: Any]] { items.map { ["i": $0.0, "value": $0.1] } }
        // The password is index 3: nothing is touched, not even the name.
        let refused = try await run(web, PageScripts.fill(key: "__t", snap: 1, fields: fields([(0, "Ada"), (3, "x")])))
        XCTAssertEqual(refused["error"] as? String, "secret_field")
        let still = try await web.evaluateJavaScript("document.getElementById('n').value") as? String
        XCTAssertEqual(still, "")
        let done = try await run(web, PageScripts.fill(key: "__t", snap: 1, fields: fields([(0, "Ada"), (1, "blue"), (2, "true")])))
        let rows = try XCTUnwrap(done["fields"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["taken"] as? Bool }, [true, true, true])
        let events = try await web.evaluateJavaScript("seen.join()") as? String
        XCTAssertEqual(events, "input,change")
        XCTAssertEqual((done["invalid"] as? [Any])?.count, 0)
        // A required field left empty is reported with the browser's words.
        let empty = try await run(web, PageScripts.fill(key: "__t", snap: 1, fields: fields([(0, "")])))
        XCTAssertEqual((empty["invalid"] as? [[String: Any]])?.count, 1)
    }

    func testTheSnapshotChangesWithThePageAndNamesTheTarget() async throws {
        let web = try await page("<form><input name=q aria-label=Q><button>Go</button></form>")
        _ = try await read(web)
        let one = try await run(web, PageScripts.snapshot(key: "__t", snap: 1, index: 1))
        XCTAssertEqual((one["target"] as? [String: Any])?["submits"] as? Bool, true)
        _ = try await web.evaluateJavaScript("localStorage.setItem('k','v'); document.body.append('hello')")
        let two = try await run(web, PageScripts.snapshot(key: "__t", snap: 1, index: 1))
        XCTAssertNotEqual(one["hash"] as? String, two["hash"] as? String)
        let storage = two["storage"] as? [String: Any]
        XCTAssertNotNil((storage?["local"] as? [String: Any])?["k"])
        XCTAssertFalse(String(describing: two).contains("\"v\""), "values are never given")
    }
}
