import CairnProtocol
import WebKit
import XCTest
@testable import Search

/// A page held still before it is read or clicked, and what changed on it
/// between two reads.
@MainActor
final class AgentPageDiffTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    // MARK: - holding still

    private func sample(_ mutations: Int, _ frames: Int, _ boxes: String = "1:0") -> PageSettle.Sample {
        PageSettle.Sample(mutations: mutations, frames: frames, boxes: boxes)
    }

    func testStillAcrossTwoFrames() {
        var settle = PageSettle()
        XCTAssertEqual(settle.take(sample(0, 0), at: 0), .wait)
        XCTAssertEqual(settle.take(sample(0, 1), at: 0.05), .wait, "one frame isn't two")
        XCTAssertEqual(settle.take(sample(0, 2), at: 0.1), .settled)
    }

    func testAChangeStartsTheCountAgain() {
        var settle = PageSettle()
        XCTAssertEqual(settle.take(sample(0, 0), at: 0), .wait)
        XCTAssertEqual(settle.take(sample(3, 2), at: 0.05), .wait, "the document changed")
        XCTAssertEqual(settle.take(sample(3, 4, "1:9"), at: 0.1), .wait, "a control moved")
        XCTAssertEqual(settle.take(sample(3, 6, "1:9"), at: 0.15), .settled)
    }

    func testAPageThatDrawsNothingIsStillWhenQuiet() {
        var settle = PageSettle()
        XCTAssertEqual(settle.take(sample(0, 0), at: 0), .wait)
        XCTAssertEqual(settle.take(sample(0, 0), at: 0.1), .wait)
        XCTAssertEqual(settle.take(sample(0, 0), at: 0.31), .settled)
    }

    func testAPageThatNeverStopsIsGivenUpOn() {
        var settle = PageSettle()
        var verdict = PageSettle.Verdict.wait
        var at = 0.0, n = 0
        while verdict == .wait, n < 1000 {
            verdict = settle.take(sample(n, n * 2), at: at)
            at += PageSettle.interval
            n += 1
        }
        XCTAssertEqual(verdict, .gaveUp)
        XCTAssertLessThanOrEqual(at, PageSettle.longest + 2 * PageSettle.interval)
    }

    // MARK: - differences

    private var asked: PageSnapshot.Asked {
        var asked = PageSnapshot.Asked()
        asked.most = 300
        asked.longest = 20000
        return asked
    }

    private func read(_ nodes: [[String: Any]], text: String = "", url: String = "https://a.example/x", cut: Bool = false) -> PageSnapshot {
        PageSnapshot(["url": url, "title": "t", "text": text, "nodes": nodes, "nodesTruncated": cut], asked: asked, snap: 1)
    }

    func testAddedRemovedAndChanged() {
        let old = read([["e": 0, "role": "button", "name": "Buy"], ["e": 1, "role": "textbox", "name": "Qty", "value": "1"],
                        ["e": 2, "role": "link", "name": "Old", "box": [0, 0, 1, 1]]], text: "one\ntwo\ntwo")
        let new = read([["e": 0, "role": "button", "name": "Buy", "box": [9, 9, 1, 1]], ["e": 1, "role": "textbox", "name": "Qty", "value": "2"],
                        ["e": 3, "role": "alert", "name": "Added to cart"]], text: "one\ntwo\nthree")
        let diff = PageDiff.between(old, new)
        XCTAssertEqual(diff.added, [3])
        XCTAssertEqual(diff.removed.map(\.index), [2])
        XCTAssertEqual(diff.changed, [PageDiff.Change(index: 1, keys: ["value"])], "moving isn't a change")
        XCTAssertEqual(diff.linesAdded, ["three"])
        XCTAssertEqual(diff.linesRemoved, ["two"], "one of the two repeats went")
        XCTAssertEqual(diff.summary(of: new), "Page changed: 1 new, 1 gone, 1 changed; now showing “Added to cart”")
    }

    func testNothingChanged() {
        let one = read([["e": 0, "role": "button", "name": "Buy"]], text: "a")
        let diff = PageDiff.between(one, one)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.summary(of: one), "Nothing on the page changed")
    }

    func testTheSummaryQuotesAndCutsAndHidesThePagesWords() {
        let new = read([["e": 0, "role": "alert", "name": "sk-abcdefghijklmnopqrstuvwxyz " + String(repeating: "z", count: 300)]])
        let summary = PageDiff.between(read([]), new).summary(of: new)
        XCTAssertFalse(summary.contains("sk-abcdef"), summary)
        XCTAssertLessThan(summary.count, 120)
    }

    func testReadsThatCannotBeCompared() {
        let one = read([])
        XCTAssertNil(PageDiff.unavailable(from: one, to: one, sameDocument: true))
        XCTAssertNotNil(PageDiff.unavailable(from: one, to: one, sameDocument: false))
        XCTAssertNotNil(PageDiff.unavailable(from: one, to: read([], cut: true), sameDocument: true))
        var other = one
        other.asked.viewportOnly = true
        XCTAssertNotNil(PageDiff.unavailable(from: one, to: other, sameDocument: true))
    }

    func testManyNewLinesAreCut() {
        let new = read([], text: (0..<500).map { "line \($0)" }.joined(separator: "\n"))
        let diff = PageDiff.between(read([]), new)
        XCTAssertEqual(diff.linesAdded.count, PageDiff.mostLines)
        XCTAssertTrue(diff.linesCut)
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

    private func index(_ out: [String: Any], _ name: String) -> Int? {
        (out["nodes"] as? [[String: Any]])?.first { $0["name"] as? String == name }?["e"] as? Int
    }

    private func script(since: Int?, snap: Int) -> String {
        PageScripts.read(key: "__test", snap: snap, most: 50, longest: 500, text: true, since: since)
    }

    func testAnElementKeepsItsNumberInOneDocumentAndNeverAcrossTwo() async throws {
        let web = try await page("<!doctype html><button id=a>First</button><button id=b>Second</button>")
        defer { web.removeFromSuperview() }
        let first = try await run(web, script(since: nil, snap: 1))
        let second = try XCTUnwrap(index(first, "Second"))
        _ = try await web.evaluateJavaScript("document.getElementById('a').remove(); document.body.insertAdjacentHTML('afterbegin','<button>New</button>'); true")
        let next = try await run(web, script(since: 1, snap: 2))
        XCTAssertEqual(next["same"] as? Bool, true)
        XCTAssertEqual(next["snap"] as? Int, 1, "its handles stay good")
        XCTAssertEqual(index(next, "Second"), second)
        XCTAssertEqual(index(next, "New"), 2, "a new one is added at the end, never in a gone one's place")
        let gone = try await run(web, PageScripts.touch(key: "__test", snap: 1, index: 0, how: "click", text: nil, replace: true))
        XCTAssertEqual(gone["error"] as? String, "detached")

        // A new document: the old number must name nothing.
        web.loadHTMLString("<!doctype html><button>Pay now</button>", baseURL: URL(string: "https://agent-test.invalid/two"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let other = try await run(web, script(since: 1, snap: 2))
        XCTAssertEqual(other["same"] as? Bool, false)
        XCTAssertEqual(other["snap"] as? Int, 2)
        let stale = try await run(web, PageScripts.touch(key: "__test", snap: 1, index: 0, how: "click", text: nil, replace: true))
        XCTAssertEqual(stale["error"] as? String, "stale_element")
    }

    func testTheWatchCountsAPagesChanges() async throws {
        let web = try await page("<!doctype html><button>b</button>")
        defer { web.removeFromSuperview() }
        let looked = try await run(web, PageScripts.settleSample())
        let first = try XCTUnwrap(PageSettle.Sample(looked))
        _ = try await web.evaluateJavaScript("document.body.appendChild(document.createElement('a')).href='#'; true")
        try await Task.sleep(nanoseconds: 100_000_000)
        let again = try await run(web, PageScripts.settleSample())
        let second = try XCTUnwrap(PageSettle.Sample(again))
        XCTAssertGreaterThan(second.mutations, first.mutations)
        XCTAssertNotEqual(second.boxes, first.boxes)
        // The page sees nothing of it, and it is taken away after.
        let seen = try await web.evaluateJavaScript("typeof window.__searchSettle") as? String
        XCTAssertEqual(seen, "undefined")
        _ = try await run(web, PageScripts.settleDone())
        let after = try await web.evaluateJavaScript("typeof globalThis.__searchSettle", contentWorld: Web.world) as? String
        XCTAssertEqual(after, "undefined")
    }

    func testThePanelsStepListTakesAConsequenceOnlyWhileRunning() {
        let session = ClaudeSession(world: nil)
        session.seed(question: "q", answer: "", steps: ["Reading the page"])
        session.consequence("Page changed: 1 new")
        XCTAssertEqual(session.turns.last?.steps, ["Reading the page"], "a finished turn's list is left alone")
    }

    func testReadPageOffersADiff() {
        let tool = MCPTools.all.first { $0.name == "read_page" }
        XCTAssertTrue(tool?.passes.contains("diff") == true)
    }
}
